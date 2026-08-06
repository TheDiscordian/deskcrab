#!/usr/bin/env python3
"""HTTP front end for DeskCrab — the phone talks to this, the laptop does the work.

The phone is a terminal: microphone, speaker, screen. Everything that makes the
assistant itself (the claude CLI, its tools, the project memory, the wants file,
the conversation) stays on this machine. A remote turn is:

    POST /ask  (raw audio body)
      -> ffmpeg  : whatever the browser recorded -> 16 kHz mono wav
      -> whisper-cli (BATCH, not whisper-stream — the clip is already complete,
                      which is both simpler and faster than the desktop's
                      settle-and-poll loop)
      -> crab remote --voice "<text>"   (same conversation, same prompt)
      -> JSON    : {transcript, spoken, display_html, audio}

Stdlib only, deliberately: no pip, no uv download, no virtualenv to go stale —
it must still start on a laptop that is offline. `markdown` is optional; without
it the display channel is shown as preformatted text.

Started by `crab serve`, which passes config through DESKCRAB_* env vars and
refuses to run without a shared secret. The listener binds loopback by default;
publishing it to a phone is a separate, deliberate act (Tailscale).
"""

import hashlib
import hmac
import http.cookies
import json
import os
import mimetypes
import queue
import re
import subprocess
import ssl
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

LIB_DIR = Path(__file__).resolve().parent
WEBAPP_DIR = LIB_DIR / "webapp"

PORT = int(os.environ.get("DESKCRAB_SERVE_PORT", "8723"))
BIND = os.environ.get("DESKCRAB_SERVE_BIND", "127.0.0.1")
SECRET = os.environ.get("DESKCRAB_SERVE_SECRET", "")
WHISPER_MODEL = os.environ.get("DESKCRAB_WHISPER_MODEL", "")
CRAB_BIN = os.environ.get("DESKCRAB_CRAB_BIN", "crab")
NAME = os.environ.get("DESKCRAB_NOTIFY_NAME") or os.environ.get(
    "DESKCRAB_ASSISTANT_NAME", "DeskCrab"
)

# A remote turn is a full claude run; it can legitimately take a while.
CERT = os.environ.get("DESKCRAB_SERVE_CERT", "")
KEY = os.environ.get("DESKCRAB_SERVE_KEY", "")

TURN_TIMEOUT = int(os.environ.get("DESKCRAB_SERVE_TIMEOUT", "600"))
MAX_UPLOAD = 25 * 1024 * 1024

if not SECRET:
    sys.exit("serve.py: DESKCRAB_SERVE_SECRET is required (set SERVE_SECRET in the config)")

try:
    import markdown as _markdown
except ImportError:
    _markdown = None


def render_markdown(text):
    if not text.strip():
        return ""
    if _markdown is None:
        from html import escape

        return "<pre>" + escape(text) + "</pre>"
    return publish_local_images(
        _markdown.markdown(text, extensions=["fenced_code", "tables"]))


# Display markdown routinely points <img> at a local file (/tmp/cat.jpg), which
# means nothing to a phone. Each such path gets a token and is served back over
# this connection; nothing is exposed that a reply did not deliberately name.
IMAGES = {}
IMG_RE = re.compile(r'(<img\b[^>]*?\bsrc=")([^"]+)(")', re.I)


def publish_local_images(html):
    def sub(m):
        src = m.group(2)
        if "://" in src or src.startswith("//") or src.startswith("/img/"):
            return m.group(0)
        p = Path(src[7:] if src.startswith("file://") else src).expanduser()
        try:
            p = p.resolve(strict=True)
        except OSError:
            return m.group(0)
        if not p.is_file():
            return m.group(0)
        token = hashlib.sha256(str(p).encode()).hexdigest()[:24]
        IMAGES[token] = p
        return m.group(1) + "/img/" + token + m.group(3)

    return IMG_RE.sub(sub, html)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, timeout=TURN_TIMEOUT, **kw)


def _suffix_for(ctype):
    """Chrome records webm/opus, iOS Safari mp4/aac — ffmpeg wants a hint."""
    if "mp4" in ctype or "aac" in ctype:
        return ".mp4"
    if "ogg" in ctype:
        return ".ogg"
    return ".webm"


def transcribe(blob, suffix):
    """Browser recording -> text. ffmpeg decodes whatever container arrived."""
    tmp = Path(tempfile.gettempdir())
    stamp = uuid.uuid4().hex[:12]
    raw = tmp / f"deskcrab-upload-{stamp}{suffix}"
    wav = tmp / f"deskcrab-upload-{stamp}.wav"
    raw.write_bytes(blob)
    try:
        r = run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw),
                 "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)])
        if r.returncode != 0 or not wav.exists() or wav.stat().st_size == 0:
            return "", "audio could not be decoded"
        r = run(["whisper-cli", "-m", WHISPER_MODEL, "-f", str(wav), "-nt", "-np"])
        if r.returncode != 0:
            return "", "transcription failed"
        text = " ".join(r.stdout.decode("utf-8", "replace").split()).strip()
        # whisper emits these for silence; they are not something anybody said.
        if text.lower() in ("[blank_audio]", "(silence)", "[silence]", "."):
            text = ""
        return text, None
    finally:
        for f in (raw, wav):
            f.unlink(missing_ok=True)


class Speaker:
    """Voices text blocks as they stream in, one at a time and in order.

    The desktop speaks every text block through piper while the turn is still
    running; the phone gets the same thing as a series of opus clips. Synthesis
    runs on its own thread so tailing the log never blocks, and strictly
    sequentially — a reply spoken out of order is worse than one spoken late.
    """

    def __init__(self, emit):
        self.emit = emit
        self.queue = queue.Queue()
        self.thread = threading.Thread(target=self._work, daemon=True)
        self.thread.start()

    def say(self, text):
        self.queue.put(text)

    def _work(self):
        while True:
            text = self.queue.get()
            if text is None:
                return
            out = os.path.join(
                tempfile.gettempdir(), f"deskcrab-remote-{uuid.uuid4().hex}.opus")
            r = run([CRAB_BIN, "synth", out, text])
            if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out):
                self.emit("voice", {"text": text,
                                    "audio": "/audio/" + os.path.basename(out)})

    def finish(self):
        self.queue.put(None)
        self.thread.join(timeout=120)


def _progress_events(logpath, stop, emit, speaker):
    """Tail a turn's stream-json log and report what the assistant is doing.

    The desktop client shows thinking and tool use as it happens; without this
    the phone stares at a spinner for the whole turn. Same stream, different
    consumer — we only summarise, the TTS streamer is not involved here.
    """
    seen_tools = 0
    while not stop.is_set() and not os.path.exists(logpath):
        time.sleep(0.05)
    try:
        with open(logpath, "r", errors="replace") as f:
            while not stop.is_set():
                line = f.readline()
                if not line:
                    time.sleep(0.05)
                    continue
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") == "result":
                    return
                if d.get("type") != "assistant" or "message" not in d:
                    continue
                for block in d["message"].get("content", []):
                    kind = block.get("type")
                    if kind == "thinking":
                        thought = " ".join((block.get("thinking") or "").split())
                        if thought:
                            emit("thinking", thought[-400:])
                    elif kind == "tool_use":
                        seen_tools += 1
                        emit("tool", _tool_label(block))
                    elif kind == "text":
                        said = " ".join((block.get("text") or "").split())
                        said = said.split("---DISPLAY---")[0].strip()
                        if said:
                            emit("text", said[:400])
                            # Speak it now, exactly as the desktop's TTS
                            # streamer does — every text block gets a voice, not
                            # just the final one.
                            if speaker:
                                speaker.say(said)
    except OSError:
        return


def _tool_label(block):
    """A short human line for a tool call — the command, not the whole payload."""
    name = block.get("name", "tool")
    inp = block.get("input") or {}
    for field in ("command", "pattern", "file_path", "path", "query", "url", "prompt"):
        val = inp.get(field)
        if isinstance(val, str) and val.strip():
            return f"{name}: {' '.join(val.split())[:120]}"
    return name


def ask(text, on_event=None, speaker=None):
    """One turn through the real assistant. Returns the crab remote JSON.

    With on_event, progress is reported live while the turn runs. With speaker,
    each text block is also voiced as it arrives instead of only at the end.
    """
    if on_event is None:
        r = run([CRAB_BIN, "remote", "--voice", text])
    else:
        logpath = f"/tmp/deskcrab-turn-{uuid.uuid4().hex}.log"
        stop = threading.Event()
        watcher = threading.Thread(
            target=_progress_events, args=(logpath, stop, on_event, speaker),
            daemon=True,
        )
        watcher.start()
        env = dict(os.environ, DESKCRAB_REMOTE_LOG=logpath)
        try:
            r = run([CRAB_BIN, "remote", "--voice", text], env=env)
        finally:
            stop.set()
            watcher.join(timeout=1)
            if speaker:
                speaker.finish()
            Path(logpath).unlink(missing_ok=True)
    out = r.stdout.decode("utf-8", "replace").strip()
    # crab remote prints exactly one JSON object last; anything a tool leaked to
    # stdout before it would otherwise poison the parse.
    for line in reversed(out.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {"spoken": "", "display": "", "audio": "",
            "error": r.stderr.decode("utf-8", "replace")[-500:] or "no response"}


class Handler(BaseHTTPRequestHandler):
    server_version = "deskcrab"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s  %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # --- plumbing ---

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # The app is a single page talking only to its own origin.
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj), "application/json; charset=utf-8", extra)

    def _presented_key(self):
        header = self.headers.get("X-Crab-Key")
        if header:
            return header
        raw = self.headers.get("Cookie")
        if raw:
            jar = http.cookies.SimpleCookie()
            try:
                jar.load(raw)
            except http.cookies.CookieError:
                return None
            if "crabkey" in jar:
                return jar["crabkey"].value
        return None

    def _authed(self, query_key=None):
        for candidate in (query_key, self._presented_key()):
            if candidate and hmac.compare_digest(candidate, SECRET):
                return True
        return False

    # --- routes ---

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        query_key = (query.get("k") or [None])[0]
        path = url.path

        if path == "/health":
            return self._json(200, {"ok": True, "name": NAME})

        if not self._authed(query_key):
            # No hint about what is running here for an unauthenticated caller.
            return self._send(404, "not found")

        # Arriving with ?k=... stores the key so the installed PWA needs no
        # querystring afterwards.
        extra = {}
        if query_key:
            extra["Set-Cookie"] = (
                f"crabkey={query_key}; Path=/; Max-Age=31536000; "
                "SameSite=Strict; HttpOnly"
            )

        if path in ("/", "/index.html"):
            return self._send(200, (WEBAPP_DIR / "index.html").read_bytes(),
                              "text/html; charset=utf-8", extra)
        if path == "/manifest.webmanifest":
            # The installed app launches in its own context, which may not carry
            # the cookie, so bake the key into start_url.
            doc = json.loads((WEBAPP_DIR / "manifest.webmanifest").read_text())
            doc["start_url"] = "/?k=" + SECRET
            return self._send(200, json.dumps(doc),
                              "application/manifest+json", extra)
        if path == "/sw.js":
            return self._send(200, (WEBAPP_DIR / "sw.js").read_bytes(),
                              "application/javascript", extra)
        if path == "/icon.svg":
            return self._send(200, (WEBAPP_DIR / "icon.svg").read_bytes(),
                              "image/svg+xml", extra)
        if path.startswith("/img/"):
            f = IMAGES.get(os.path.basename(path))
            if f is None or not f.is_file():
                return self._send(404, "not found")
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            return self._send(200, f.read_bytes(), ctype, extra)
        if path.startswith("/audio/"):
            name = os.path.basename(path)
            # Only ever serve this server's own generated replies.
            if not name.startswith("deskcrab-remote-") or not name.endswith(".opus"):
                return self._send(404, "not found")
            f = Path(tempfile.gettempdir()) / name
            if not f.exists():
                return self._send(404, "not found")
            return self._send(200, f.read_bytes(), "audio/ogg", extra)

        return self._send(404, "not found")

    def do_POST(self):
        if not self._authed():
            return self._send(404, "not found")
        url = urlparse(self.path)

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_UPLOAD:
            return self._json(400, {"error": "bad body length"})
        body = self.rfile.read(length)

        if url.path == "/transcribe":
            # Speech recognition only. The client shows the transcript the
            # instant it lands and asks for the answer separately, so a
            # mis-heard sentence is visible before the long wait, not after.
            ctype = self.headers.get("X-Audio-Type", "audio/webm")
            text, err = transcribe(body, _suffix_for(ctype))
            if err:
                return self._json(200, {"error": err})
            if not text:
                return self._json(200, {"error": "no speech detected"})
            return self._json(200, {"transcript": text})

        if url.path == "/ask":
            ctype = self.headers.get("X-Audio-Type", "audio/webm")
            text, err = transcribe(body, _suffix_for(ctype))
            if err:
                return self._json(200, {"error": err})
            if not text:
                return self._json(200, {"error": "no speech detected"})
        elif url.path == "/say":
            try:
                text = json.loads(body.decode("utf-8")).get("text", "").strip()
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            if not text:
                return self._json(200, {"error": "empty message"})
        else:
            return self._send(404, "not found")

        # The answer is streamed, not returned in one lump: the desktop client
        # shows thinking and tool use as it happens and the phone should too.
        # Plain chunked SSE over the same POST — no second connection to
        # authenticate, correlate, and clean up.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        lock = threading.Lock()
        alive = [True]

        def event(kind, payload):
            if not alive[0]:
                return
            body = json.dumps({"kind": kind, **payload})
            with lock:
                try:
                    chunk = f"data: {body}\n\n".encode("utf-8")
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ValueError):
                    # He backgrounded the app or lost signal; the turn itself
                    # carries on and lands in the conversation regardless.
                    alive[0] = False

        event("transcript", {"text": text})
        try:
            speaker = Speaker(event)
            reply = ask(text, on_event=lambda kind, msg: event(kind, {"text": msg}),
                        speaker=speaker)
            # Everything sayable was already streamed as voice clips; replaying
            # crab's own render of the same words would say it all twice.
            audio = ""
            event("done", {
                "spoken": reply.get("spoken", ""),
                "display_html": render_markdown(reply.get("display", "")),
                "audio": audio,
                "error": reply.get("error", ""),
            })
        except Exception as exc:  # noqa: BLE001 — the client must hear about it
            event("done", {"spoken": "", "display_html": "", "audio": "",
                           "error": str(exc)[:300]})
        with lock:
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ValueError):
                pass
        return


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True

    scheme = "http"
    if CERT and KEY:
        # A browser only grants microphone access over https (or to localhost),
        # so a phone client needs TLS from somewhere: either here, or from a
        # proxy like `tailscale serve` that terminates it in front of us.
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT, KEY)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    print(f"{NAME} is listening on {scheme}://{BIND}:{PORT}/?k=<secret>")
    if scheme == "http":
        print("To reach it from a phone: tailscale serve --bg https / "
              f"http://127.0.0.1:{PORT}   (or set SERVE_TLS=self)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
