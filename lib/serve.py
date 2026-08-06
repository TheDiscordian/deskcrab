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

import hmac
import http.cookies
import json
import os
import subprocess
import ssl
import sys
import tempfile
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
    return _markdown.markdown(text, extensions=["fenced_code", "tables"])


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


def ask(text):
    """One turn through the real assistant. Returns the crab remote JSON."""
    r = run([CRAB_BIN, "remote", "--voice", text])
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
            return self._send(200, (WEBAPP_DIR / "manifest.webmanifest").read_bytes(),
                              "application/manifest+json", extra)
        if path == "/sw.js":
            return self._send(200, (WEBAPP_DIR / "sw.js").read_bytes(),
                              "application/javascript", extra)
        if path == "/icon.svg":
            return self._send(200, (WEBAPP_DIR / "icon.svg").read_bytes(),
                              "image/svg+xml", extra)
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

        reply = ask(text)
        audio = reply.get("audio") or ""
        return self._json(200, {
            "transcript": text,
            "spoken": reply.get("spoken", ""),
            "display_html": render_markdown(reply.get("display", "")),
            "audio": "/audio/" + os.path.basename(audio) if audio else "",
            "error": reply.get("error", ""),
        })


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
