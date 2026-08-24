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

import contextlib
import hashlib
import hmac
import http.cookies
import json
import os
import mimetypes
import queue
import re
import signal
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

# The desk streamer's sentence chunker, shared (specs/phone.md rule 17;
# specs/speech-output.md's one-chunker discipline). Stdlib-only itself, so the
# server's no-dependencies promise holds.
sys.path.insert(0, str(LIB_DIR))
import sentence_stream
# The token ledger's aggregation (specs/metrics.md rules 21-22): the metrics
# page rides this server rather than getting one of its own. Stdlib-only, so
# the no-dependencies promise holds here too.
import token_ledger

# Streaming voice granularity (PHONE_SENTENCE_STREAM in the config). Off, this
# file behaves byte-for-byte as before the flag existed: one clip per completed
# block. On, the text deltas already present in the turn log are chunked into
# sentences and each becomes a clip the moment it completes; the completed
# block then voices only the tail the deltas had not spoken.
SENTENCE_STREAM = os.environ.get("DESKCRAB_PHONE_SENTENCE_STREAM", "") == "1"

PORT = int(os.environ.get("DESKCRAB_SERVE_PORT", "8723"))
BIND = os.environ.get("DESKCRAB_SERVE_BIND", "127.0.0.1")
SECRET = os.environ.get("DESKCRAB_SERVE_SECRET", "")
WHISPER_MODEL = os.environ.get("DESKCRAB_WHISPER_MODEL", "")
WHISPER_FIXES = os.environ.get("DESKCRAB_WHISPER_FIXES", "")
CRAB_BIN = os.environ.get("DESKCRAB_CRAB_BIN", "crab")
NAME = os.environ.get("DESKCRAB_NOTIFY_NAME") or os.environ.get(
    "DESKCRAB_ASSISTANT_NAME", "DeskCrab"
)

# Turn metrics (specs/turn-pipeline.md rule 33). The server is the first to
# see a phone turn's first tool call and its first synthesised clip, so those
# two stamps are written here, under the server's own pid with the turn's
# stream-log name as the correlator. Best-effort: a stamp that cannot be
# written costs nothing.
METRICS_DIR = os.environ.get("DESKCRAB_METRICS_DIR", "")


def turn_metric(stage, detail=""):
    if not METRICS_DIR:
        return
    try:
        os.makedirs(METRICS_DIR, exist_ok=True)
        path = os.path.join(METRICS_DIR, time.strftime("%Y-%m-%d") + ".log")
        with open(path, "a") as fh:
            fh.write("%.3f\t%d\t%s\t%s\t%s\n"
                     % (time.time(), os.getpid(), "phone-serve", stage, detail))
    except OSError:
        pass

# A remote turn is a full claude run; it can legitimately take a while.
CERT = os.environ.get("DESKCRAB_SERVE_CERT", "")
KEY = os.environ.get("DESKCRAB_SERVE_KEY", "")

TURN_TIMEOUT = int(os.environ.get("DESKCRAB_SERVE_TIMEOUT", "600"))
MAX_UPLOAD = 25 * 1024 * 1024

# specs/phone.md rule 24: the secret MUST NEVER be written to a log. It rides
# in the query string of the installed start URL, so every PWA launch puts it
# on the request line — and the request line is what the access log is. The
# journal this server writes to is readable by anything on the box and keeps
# the line long after the secret is rotated.
#
# Two passes, because there are two ways it can arrive. The pattern catches the
# query form even when the value is not the secret in hand (a wrong key logged
# is still a credential somebody typed); the literal replacement catches it
# anywhere else a line can carry it — a header echo, a cookie, an exception
# rendering a URL.
_QUERY_KEY_RE = re.compile(r"([?&]k=)[^&\s\"']*")


def redact_secret(line):
    line = _QUERY_KEY_RE.sub(r"\1<redacted>", line)
    if SECRET:
        line = line.replace(SECRET, "<redacted>")
    return line

# The header opening a block in the conversation file, with the local-time
# stamp common.sh now writes: "User [2026-08-07 12:01]: …". The stamp group is
# optional on purpose — conversations written before stamping, and every
# archive of one, must keep parsing here unchanged. So is the parenthesised
# mark ("Assistant [stamp] (autonomous wake): …") — same shape as
# CONVO_MARK_RE in common.sh; a header pattern narrower than the writer's
# drops every wake reply from the phone without an error anywhere.
BLOCK_HDR = re.compile(r"^(User|Assistant)( \[[^\]]*\])?( \([^)]*\))?: ")

# How many turns are being answered right now. Restarting the server kills the
# claude process mid-answer and drops whoever is on the wire, so anything that
# wants to restart asks /health first and waits for this to reach zero.
_IN_FLIGHT = [0]
_IN_FLIGHT_LOCK = threading.Lock()


def turns_in_flight():
    with _IN_FLIGHT_LOCK:
        return _IN_FLIGHT[0]


@contextlib.contextmanager
def turn_in_flight():
    with _IN_FLIGHT_LOCK:
        _IN_FLIGHT[0] += 1
    try:
        yield
    finally:
        with _IN_FLIGHT_LOCK:
            _IN_FLIGHT[0] -= 1


# Graceful restart: SIGTERM (what `systemctl restart` sends) means "finish the
# sentence, then go", not "drop whoever is on the wire". While draining, no new
# turn may start — the client re-POSTs the same turn id with backoff, so a
# refused turn lands on the fresh server instead — but attaching to a turn
# already in flight keeps working, because that reply is what the drain exists
# to protect. Once the last turn finishes (and its tail has had a moment to
# flush to attached sockets) the listener stops and the process exits. The
# unit must pair this with KillMode=mixed, or systemd SIGTERMs the whole
# cgroup and the in-flight claude dies regardless of anything done here.
_DRAINING = threading.Event()
_HTTPD = [None]

# Seconds to keep serving after the last turn finishes, so a client still
# tailing the buffer receives the done event before the socket dies with us.
DRAIN_LINGER = int(os.environ.get("DESKCRAB_SERVE_DRAIN_LINGER", "5"))


def _drain_worker():
    started = time.time()
    # A turn's subprocesses are already capped at TURN_TIMEOUT, so the drain
    # can only exceed it if something is wedged — at which point the reply is
    # lost either way and exiting is the right move.
    deadline = started + TURN_TIMEOUT + 30
    waited = False
    while turns_in_flight() and time.time() < deadline:
        waited = True
        time.sleep(0.5)
    if turns_in_flight():
        print(f"drain: gave up on {turns_in_flight()} wedged turn(s) after "
              f"{int(time.time() - started)}s", flush=True)
    elif waited:
        time.sleep(DRAIN_LINGER)
    if _HTTPD[0] is not None:
        _HTTPD[0].shutdown()


def _on_sigterm(signum, frame):
    if _DRAINING.is_set():
        return
    _DRAINING.set()
    print(f"SIGTERM: draining ({turns_in_flight()} turn(s) in flight)",
          flush=True)
    threading.Thread(target=_drain_worker, daemon=True).start()


# --- per-turn event buffers -------------------------------------------------
#
# The laptop's uplink is a phone hotspot, so the client's connection routinely
# dies mid-turn. Every event a turn produces is therefore buffered here as well
# as written to the socket; a client that reconnects asks /turn/<id>?from=<n>
# and gets exactly the events it missed, then follows live. The turn itself
# runs on its own thread, so a dead socket never kills the claude process.

TURN_BUFFER_TTL = int(os.environ.get("DESKCRAB_SERVE_TURN_TTL", "3600"))


class TurnStopped(Exception):
    """The user pulled the brake on this turn (spec rule 47). Raised by run()
    so a killed subprocess is never mistaken for a reply, and caught in
    run_turn, where it becomes the turn's one completion event."""


class Turn:
    def __init__(self, tid):
        self.tid = tid
        self.events = []
        self.done = False
        self.created = time.time()
        self.cond = threading.Condition()
        # The brake (spec rules 47-48). `stopped` is set by /stop before any
        # signal is sent, so a process that races the kill — or has not been
        # spawned yet — still dies at the next checkpoint in run(). `procs`
        # holds the pids of the live process GROUPS this turn started (crab
        # remote, crab synth): run() gives every child its own group, so each
        # pid here is a pgid and a killpg reaches the whole tree under it.
        self.stopped = False
        self.procs = set()

    def emit(self, kind, payload):
        with self.cond:
            self.events.append({"kind": kind, **payload})
            if kind == "done":
                self.done = True
            self.cond.notify_all()

    def give_up(self, error):
        """The done event a wedged turn will never send — at most once, so
        racing tails cannot double it, and never over a real completion."""
        with self.cond:
            if self.done:
                return
            self.events.append({"kind": "done", "spoken": "", "display_html": "",
                                "audio": "", "error": error})
            self.done = True
            self.cond.notify_all()


TURNS = {}
TURNS_LOCK = threading.Lock()


def get_turn(tid, create=False):
    """Look up (and atomically maybe create) a turn buffer.

    Returns (turn, created). Two racing requests with the same id get the same
    buffer and exactly one `created=True` — the loser attaches instead of
    running the turn twice.
    """
    with TURNS_LOCK:
        now = time.time()
        for dead in [k for k, v in TURNS.items()
                     if v.done and now - v.created > TURN_BUFFER_TTL]:
            TURNS.pop(dead)
        t = TURNS.get(tid)
        if t is None and create:
            TURNS[tid] = t = Turn(tid)
            return t, True
        return t, False


def _clean_tid(raw):
    """Client-supplied turn id, hex only. Empty/absent -> fresh server id."""
    tid = re.sub(r"[^a-f0-9]", "", (raw or "").lower())[:64]
    return tid or uuid.uuid4().hex


# The brake (spec rules 47-48). SIGTERM first so bash and the CLI get to die
# cleanly, then SIGKILL after a short grace for anything that ignored it. The
# grace is short on purpose: a stop is the user saying NOW.
STOP_GRACE = float(os.environ.get("DESKCRAB_SERVE_STOP_GRACE", "2"))


def stop_turn(turn):
    """Genuinely kill a turn in flight: the crab remote run behind the reply
    and any synthesis beside it, each as a whole process group.

    Marking `stopped` comes before the first signal, so a child that races the
    sweep — or has not been spawned yet — still dies at run()'s checkpoints.
    The one-mind lock needs no step of its own: crab remote holds it on an
    open descriptor, and the kernel releases it with the process. The turn's
    completion event is not emitted here — run_turn's thread owns it (rule 6,
    exactly one), and TurnStopped carries it there the moment the wait on the
    killed child returns.

    Returns False when the turn was already done, True when a stop was set in
    motion."""
    with turn.cond:
        if turn.done:
            return False
        turn.stopped = True
        pgids = list(turn.procs)
    # The stop takes the message with it (spec rules 50, 52): a stopped turn's
    # mid-turn spool entry must not surface later in a run it no longer owns.
    unspool_midturn(turn.tid)
    for pg in pgids:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(pg, signal.SIGTERM)
    deadline = time.time() + STOP_GRACE
    while time.time() < deadline:
        with turn.cond:
            if not turn.procs:
                break
        time.sleep(0.05)
    for pg in pgids:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(pg, signal.SIGKILL)
    print("stop: turn %s stopped by hand — %d process group(s) signalled"
          % (turn.tid[:8], len(pgids)), file=sys.stderr, flush=True)
    return True


# Playback truth (specs/phone.md rules 44-46). The completion event proves the
# reply reached the wire, not the ear: on 2026-08-09 two long replies were
# delivered in full and played nothing — every synthesis of the turn had
# quietly failed — and the only witness was the silence, reported by hand.
# The client posts what its audio element actually did, per turn and per clip;
# the reports land in the metrics log beside the synth stamps, and a turn
# whose text was delivered with no started report inside the alarm window
# raises exactly one `crab notify`.
PLAY_ALARM = int(os.environ.get("DESKCRAB_SERVE_PLAY_ALARM", "90"))

PLAYBACK = {}
PLAYBACK_LOCK = threading.Lock()
# Any valid report ever, this process. A page from before rule 44 reports
# nothing at all; notifying on every one of its turns would be an old client
# degrading into a nightly page of the house (the MAJ-19 shape), so the alarm
# only notifies once some client has proven it reports.
PLAY_CAPABLE = [False]


def playback_state(tid):
    with PLAYBACK_LOCK:
        now = time.time()
        for dead in [k for k, v in PLAYBACK.items()
                     if now - v["created"] > TURN_BUFFER_TTL]:
            PLAYBACK.pop(dead)
        st = PLAYBACK.get(tid)
        if st is None:
            st = PLAYBACK[tid] = {"created": now, "started": False,
                                  "stopped": False, "last_error": "",
                                  "alarmed": False,
                                  # per-clip playback truth (phone.md rules 39
                                  # and 46a): clip index -> the furthest state
                                  # reported for it, and when the last report
                                  # of any kind landed
                                  "clips": {}, "last_report": 0.0}
        return st


def _silence_alarm(tid, clips_offered):
    """One notification for one turn nobody fully heard, and never a second.

    Two shapes share the one alarm and the one-notification discipline: the
    wholly silent turn (rule 46 — text delivered, nothing ever started), and
    the mid-queue death (rule 46a — earlier clips started, a later clip was
    queued and never reported started, and until 2026-08-22 that loss left no
    server-side trace at all: the 00:40 turn's last two clips were synthesised,
    delivered as events, and died with the page).
    """
    st = playback_state(tid)
    with PLAYBACK_LOCK:
        if st["stopped"] or st["alarmed"]:
            return
        dead_tail = ""
        if st["started"]:
            # Some of the turn was heard. A clip still only "requested" at
            # alarm time never started; a client still legitimately working
            # through a long backlog is reporting as it goes, so a recent
            # report of any kind stands the alarm down.
            if time.time() - st["last_report"] < PLAY_ALARM / 2.0:
                return
            stuck = sorted(k for k, v in st["clips"].items()
                           if v == "requested")
            if not stuck:
                return
            dead_tail = ("the voice died mid-reply: clip %s of %d never "
                         "played" % (stuck[0], len(st["clips"])))
        st["alarmed"] = True
        reason = st["last_error"]
        capable = PLAY_CAPABLE[0]
    if dead_tail:
        reason = dead_tail
    elif not reason:
        reason = ("no clip was ever synthesised" if not clips_offered
                  else "%d clip(s) offered, none reported playing"
                  % clips_offered)
    turn_metric("dead-tail" if dead_tail else "silent-turn",
                "turn %s — %s" % (tid[:8], reason))
    print("playback: turn %s delivered its text but was not fully heard — %s"
          % (tid[:8], reason), file=sys.stderr, flush=True)
    if not capable:
        return
    body = ("A phone reply lost its tail: %s (turn %s)." % (reason, tid[:8])
            if dead_tail else
            "A phone reply went silent: the text arrived but no audio ever "
            "played (turn %s — %s)." % (tid[:8], reason))
    try:
        subprocess.run(
            [CRAB_BIN, "notify", body],
            capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print("playback: crab notify failed for turn %s: %s" % (tid[:8], exc),
              file=sys.stderr, flush=True)


def arm_silence_alarm(tid, clips_offered):
    st = playback_state(tid)
    with PLAYBACK_LOCK:
        # A turn that already started sounding still gets the timer: the
        # mid-queue death (rule 46a) is exactly a turn whose FIRST clips
        # played — only a chosen stop stands the whole alarm down here.
        if st["stopped"]:
            return
    t = threading.Timer(PLAY_ALARM, _silence_alarm, args=(tid, clips_offered))
    t.daemon = True
    t.start()


# A queued turn used to be dead air (spec rule 43): the runner serialises on
# the remote lock with a bounded wait of up to ten minutes, and for all of it
# nothing reached this buffer — the tail carried keepalives, the page showed a
# frozen status, and the reload storm began. Measured live on 2026-08-09: a
# message waited 203 s behind a four-minute turn and the page was hand reloaded
# four times. So until the run shows its first real sign of life, a watcher
# says what the wait is, and its notes count as progress on the client's
# deadline — a turn visibly in line is not a turn gone silent.
QUEUE_NOTE_AFTER = int(os.environ.get("DESKCRAB_SERVE_QUEUE_NOTE_AFTER", "15"))
QUEUE_NOTE_EVERY = int(os.environ.get("DESKCRAB_SERVE_QUEUE_NOTE_EVERY", "25"))


def _turn_started(turn):
    """Whether the run has produced anything beyond its own transcript echo
    and the queue watcher's wait notes — the first real sign the model is up."""
    with turn.cond:
        return turn.done or any(
            e["kind"] not in ("transcript", "wait") for e in turn.events)


def _queue_watch(turn, stop):
    started = time.time()
    if stop.wait(QUEUE_NOTE_AFTER):
        return
    while not stop.is_set() and not _turn_started(turn):
        behind = False
        with TURNS_LOCK:
            behind = any(t is not turn and not t.done for t in TURNS.values())
        mins = int((time.time() - started) // 60)
        note = ("in line — she's still finishing the previous message" if behind
                else "in line — she's in the middle of something else")
        if mins:
            note += f" ({mins} min so far)"
        turn.emit("wait", {"text": note})
        if stop.wait(QUEUE_NOTE_EVERY):
            return


def run_turn(turn, text):
    """The actual assistant turn, feeding the buffer. Socket-independent."""
    # In-flight delivery (spec rule 51): accepted while another turn is
    # running means this message parks behind the remote lock — so it goes
    # into the mid-turn spool NOW, before the park, and the running mind
    # reads it at its very next tool-call boundary instead of after its last.
    # The runner deletes this turn's own entry once it holds the lock, so the
    # entry can never come back around as this turn's own mail.
    with TURNS_LOCK:
        behind = any(t is not turn and not t.done for t in TURNS.values())
    if behind:
        spool_midturn(turn.tid, text)
    try:
        with turn_in_flight():
            stop = threading.Event()
            threading.Thread(target=_queue_watch, args=(turn, stop),
                             daemon=True).start()
            try:
                speaker = Speaker(turn.emit, turn)
                reply = ask(text,
                            on_event=lambda kind, msg: turn.emit(kind, {"text": msg}),
                            speaker=speaker, turn=turn)
            finally:
                stop.set()
            # The reply clip the turn itself synthesised is the never-silent
            # fallback: offered when and only when no streaming clip was
            # voiced, so a client that heard the clips is not made to hear
            # the reply again and a client that heard nothing still hears it
            # once. Emptying this field unconditionally was how a failed
            # streaming synthesis became total silence with a good clip
            # already sitting on disk.
            audio = ""
            if speaker.voiced == 0 and reply.get("audio"):
                audio = "/audio/" + os.path.basename(reply["audio"])
                print("speech: no streaming clip was voiced — the completion "
                      "event carries the turn's own reply clip",
                      file=sys.stderr, flush=True)
            turn.emit("done", {
                "spoken": reply.get("spoken", ""),
                "display_html": render_markdown(reply.get("display", "")),
                "audio": audio,
                "error": reply.get("error", ""),
            })
            # The reply's text is on its way; whether any of its sound is ever
            # heard is now the client's story to tell (spec rules 44-46). A
            # turn that spoke no text has nothing to be silent about, and an
            # errored turn is already surfaced by its error field.
            if reply.get("spoken", "").strip() and not reply.get("error"):
                arm_silence_alarm(turn.tid, speaker.voiced + (1 if audio else 0))
    except TurnStopped:
        # The brake (spec rule 47): the turn was killed by hand. Still exactly
        # one completion event (rule 6), marked so the client can tell a
        # chosen stop from a failure. give_up() fires only for turns hours
        # overdue, so this guard is belt only.
        with turn.cond:
            already = turn.done
        if not already:
            turn.emit("done", {"spoken": "", "display_html": "", "audio": "",
                               "error": "stopped by hand", "stopped": True})
    except Exception as exc:  # noqa: BLE001 — the client must hear about it
        turn.emit("done", {"spoken": "", "display_html": "", "audio": "",
                           "error": str(exc)[:300]})


if not SECRET:
    sys.exit("serve.py: DESKCRAB_SERVE_SECRET is required (set SERVE_SECRET in the config)")

try:
    import markdown as _markdown
except ImportError:
    _markdown = None

# Web Push (reaching the phone with the page closed) needs ECDH + AES-GCM,
# which stdlib cannot do. Same deal as `markdown`: optional. Without the
# `cryptography` package the push routes answer 501 and everything else works.
try:
    import webpush as _webpush
except ImportError:
    _webpush = None


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


def run(cmd, turn=None, **kw):
    """Captured subprocess that waits on the PROCESS — never on its pipes.

    With `turn`, the child's process group is registered on the turn for the
    life of the wait, so a /stop (spec rule 47) can reach and kill it — and
    the stop is honoured at three checkpoints: before spawning (a stopped
    turn starts nothing new), just after (a stop that raced the spawn kills
    the child it could not have seen), and after the wait (a killed child's
    output is never mistaken for a reply). Each raises TurnStopped.

    Two waits wedged here, and both were waits for EOF on a pipe rather than
    for the child. The first: subprocess.run kills only the direct child at
    the timeout, so a descendant still holding stdout kept the drain blocked
    and the turn never emitted its done event — "thinking…" forever, the
    wedge behind C10. The child gets its own process group now and the
    timeout kills the whole group, so TimeoutExpired always reaches the
    caller (spec: phone rule 6 — every turn ends in a completion event).

    The second is subtler and loses a GOOD reply: communicate() returns at
    EOF even when the child has already exited zero with its answer printed,
    so one leaked `child &` anywhere under `crab remote` made a turn that
    succeeded in seconds surface at the full timeout as a timeout error —
    from the phone, Beatrice audibly finishes speaking and the page then
    sits at "thinking…" until an error bubble replaces the reply she gave.
    Capture goes to files instead: a file has no EOF to wait on, so the wait
    ends the moment the child exits, whoever still holds the descriptor
    (tests/test_phone_done_after_exit.sh drives exactly this shape).
    """
    if turn is not None and turn.stopped:
        raise TurnStopped()
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen(cmd, stdout=out, stderr=err,
                             start_new_session=True, **kw)
        if turn is not None:
            with turn.cond:
                stopped = turn.stopped
                if not stopped:
                    turn.procs.add(p.pid)
            if stopped:
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(p.pid, signal.SIGKILL)
                p.wait()
                raise TurnStopped()
        try:
            p.wait(timeout=TURN_TIMEOUT)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            raise
        finally:
            if turn is not None:
                with turn.cond:
                    turn.procs.discard(p.pid)
        if turn is not None and turn.stopped:
            raise TurnStopped()
        out.seek(0)
        err.seek(0)
        return subprocess.CompletedProcess(cmd, p.returncode,
                                           out.read(), err.read())


STATE_PREFIX = os.environ.get("DESKCRAB_STATE_PREFIX", "/tmp/deskcrab")
CONTEXT_TURNS = int(os.environ.get("DESKCRAB_SERVE_CONTEXT_TURNS", "6"))

# The mid-turn spool (specs/phone.md rules 51-52): a message accepted while
# another turn is in flight is written here the moment it is accepted, and the
# running turn's PostToolUse hook (lib/midturn-mail) reads it at its very next
# tool-call boundary — so a course correction sent mid-task is heard mid-task,
# not after the turn ends. One file per message, named <arrival-ns>.<turn-id>.msg:
# the id is the queued turn's own, so the runner can delete its entry once it
# holds the lock and the reader can skip it — a turn must never be handed its
# own message as mail from outside.
MIDTURN_DIR = STATE_PREFIX + "-midturn"


def spool_midturn(tid, text):
    try:
        os.makedirs(MIDTURN_DIR, exist_ok=True)
        name = "%d.%s.msg" % (time.time_ns(), tid)
        tmp = os.path.join(MIDTURN_DIR, name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.rename(tmp, os.path.join(MIDTURN_DIR, name))
    except OSError as exc:
        # Best-effort: the message is not lost — its own turn still runs — it
        # is merely not surfaced mid-flight. Worth a line, never a failure.
        print("midturn: spool failed for %s: %s" % (tid[:8], exc),
              file=sys.stderr, flush=True)


def unspool_midturn(tid):
    """A stopped turn's entry leaves the spool with it (spec rule 50: a stop
    takes the queued messages along), and rule 52's never-echo holds even for
    a runner that dies before its own delete."""
    try:
        for name in os.listdir(MIDTURN_DIR):
            if name.endswith(".%s.msg" % tid):
                with contextlib.suppress(OSError):
                    os.unlink(os.path.join(MIDTURN_DIR, name))
    except OSError:
        pass

# The phone's liveness beacon: touched on every authenticated /watch poll. An
# autonomous wake deciding whether its voice belongs on the phone checks this
# file's freshness — the same channel that would deliver the audio, so a fresh
# beacon means the audio will actually be picked up.
PHONE_SEEN = STATE_PREFIX + "-phone-seen"

# Pointer a wake writes when it routes its spoken reply here instead of the
# desk speakers. Freshness is bounded so a pointer nobody collected never
# replays days later when a page finally loads.
WAKE_AUDIO = STATE_PREFIX + "-wake-audio"
WAKE_AUDIO_TTL = int(os.environ.get("DESKCRAB_SERVE_WAKE_TTL", "120"))


def read_wake():
    """The current wake-audio pointer, if it is still fresh."""
    p = Path(WAKE_AUDIO)
    try:
        if time.time() - p.stat().st_mtime > WAKE_AUDIO_TTL:
            return None
        doc = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    if doc.get("id") and doc.get("audio"):
        return {"id": str(doc["id"]), "audio": doc["audio"],
                "spoken": doc.get("spoken", "")}
    return None


# Pointer any hand writes (`crab play`) to put an audio file on the phone with
# a visible transport. Same delivery shape as the wake pointer, and the same
# reason for the TTL: a hand-off nobody collected must not start playing when
# a page finally loads later.
PLAY_FILE = STATE_PREFIX + "-play"
PLAY_TTL = int(os.environ.get("DESKCRAB_SERVE_PLAY_TTL", "120"))

# Files handed over for the phone to play, by token. Fed only by the play
# pointer, never by a request, and bounded — handing over a file is not a door
# onto the rest of the filesystem, and a dict in a long-lived process is not
# allowed to grow forever.
MEDIA = {}
MEDIA_CAP = 64


def read_play():
    """The current play pointer, if fresh and pointing at a file under home."""
    p = Path(PLAY_FILE)
    try:
        if time.time() - p.stat().st_mtime > PLAY_TTL:
            return None
        doc = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    if not doc.get("id") or not doc.get("path"):
        return None
    try:
        f = Path(str(doc["path"])).expanduser().resolve(strict=True)
    except OSError:
        return None
    # The one boundary, enforced here as well as by the writer: only a file
    # that resolves under the home directory is ever offered.
    if not f.is_file() or not f.is_relative_to(Path.home().resolve()):
        return None
    token = hashlib.sha256(str(f).encode()).hexdigest()[:24]
    MEDIA[token] = f
    while len(MEDIA) > MEDIA_CAP:
        MEDIA.pop(next(iter(MEDIA)))
    return {"id": str(doc["id"]), "url": "/media/" + token,
            "title": str(doc.get("title") or f.stem)}


def read_context():
    """Where the conversation currently stands, for seeding a freshly loaded page.

    Returns the running compaction summary (if compaction has happened at all)
    plus the last CONTEXT_TURNS exchanges still live in the convo file. Both are
    optional: a brand-new conversation yields nothing and the client shows
    nothing rather than an empty shell.
    """
    summary = ""
    sp = Path(STATE_PREFIX + "-convo-summary.txt")
    if sp.is_file():
        summary = sp.read_text(errors="replace").strip()

    turns = read_turns()
    n = len(turns)
    wake = read_wake()
    play = read_play()
    # wake_id lets a freshly loaded page mark the current wake audio as already
    # heard instead of blaring it on open; play_id does the same for a pending
    # media hand-off (spec rule 37).
    # Pairs, not messages — six exchanges reads as six exchanges.
    return {"summary": summary, "turns": turns[-(CONTEXT_TURNS * 2):], "n": n,
            "gen": turns_gen(turns, summary),
            "wake_id": wake["id"] if wake else "",
            "play_id": play["id"] if play else ""}


def read_turns():
    """Every turn still live in the convo file, oldest first."""
    turns = []
    cp = Path(STATE_PREFIX + "-convo.txt")
    if not cp.is_file():
        return turns
    cur = None
    for line in cp.read_text(errors="replace").splitlines():
        m = BLOCK_HDR.match(line)
        if m:
            # The stamp is metadata, not speech: it rides beside the bubble as
            # "time" and never inside its text. Older, unstamped lines match the
            # same pattern with the group empty and read exactly as they did.
            # The mark rides too (phone rule 42): the client's own-turn release
            # must never take a wake's reply for the answer it is waiting on,
            # and the mark is the only thing that tells them apart.
            cur = {"role": m.group(1).lower(), "text": line[m.end():],
                   "time": (m.group(2) or "").strip("[] "),
                   "mark": (m.group(3) or "").strip("() ")}
            turns.append(cur)
        elif line.startswith("[Autonomous wake"):
            # A wake marker is a turn boundary, not prose. Without this it is
            # welded onto the end of whatever turn preceded it as a
            # "continuation", polluting that bubble and hiding the fact that
            # the assistant turn that follows stands alone.
            cur = None
        elif cur is not None:
            # Continuation of a multi-line turn.
            cur["text"] += "\n" + line
    for t in turns:
        t["text"] = t["text"].strip()
        # A stored reply keeps its display channel inline. Live turns arrive
        # already split, so split these the same way — otherwise the markdown
        # lands in the spoken bubble as a wall of raw asterisks.
        if t["role"] == "assistant" and "---DISPLAY---" in t["text"]:
            spoken, _, disp = t["text"].partition("---DISPLAY---")
            t["text"] = spoken.strip()
            t["display_html"] = render_markdown(disp.strip())
    # A block holding nothing is not a turn. It reached the phone as a bare
    # empty bubble — the shape he read as "she answered me with nothing" —
    # and it is never anything the client can usefully draw. Kept only when a
    # display card hangs off it, which IS content. Dropping them here rather
    # than in the page means the /watch cursor counts what the page will
    # actually show, so nothing is silently consumed on the way past.
    return [t for t in turns if t["text"] or t.get("display_html")]


WATCH_TIMEOUT = int(os.environ.get("DESKCRAB_SERVE_WATCH_TIMEOUT", "25"))


def turns_gen(turns, summary=None):
    """Identity of this incarnation of the conversation file.

    The /watch cursor is a position in a list that compaction and archival
    rewrite, and a position in a rewritten list points at the wrong turns —
    or past the end, where the old handling snapped it down and silently
    consumed every turn that rode in with the rewrite (the first exchange of
    each freshly archived conversation, most visibly). The gen is how a
    rewrite is *detected*: derived from the summary and the first surviving
    turn, so plain appends never change it, while compaction (folds the head
    into the summary) and archival (new file, summary gone) always do.
    """
    if summary is None:
        try:
            summary = Path(STATE_PREFIX + "-convo-summary.txt").read_text(
                errors="replace")
        except OSError:
            summary = ""
    head = summary.strip()
    if turns:
        t = turns[0]
        head += "\x00" + t["role"] + "\x00" + t["time"] + "\x00" + t["text"][:200]
    return hashlib.sha1(head.encode()).hexdigest()[:12] if head else ""


def watch_turns(since, wait, wakeseen=None, gen=None, playseen=None):
    """Long-poll for turns that appeared since the caller's cursor.

    The cursor is a turn count, valid only for the incarnation of the file it
    was read from — so a client that knows its generation sends it, and the
    moment the file is rewritten (compaction, archival) the poll answers
    immediately with `reset` and the whole current list instead of a slice
    measured against a list that no longer exists. The client redraws from
    scratch, exactly as a manual refresh would. The old behaviour — snap the
    cursor down and wait — silently consumed every turn that rode in with the
    rewrite; it survives only for clients too old to send a gen.

    Wake audio rides the same poll with its own cursor: `wakeseen` is the id of
    the last wake clip the client played, and a fresh pointer with a different
    id ends the poll early so the voice arrives within a beat of being written.
    A client that sent no wakeseen at all cannot acknowledge an id, so handing
    it the wake would turn every poll into an instant return for the pointer's
    whole TTL — a hot loop. Wake delivery is strictly opt-in by the parameter's
    presence (an empty value opts in; None does not).

    A handed media file (`crab play`) rides the same way with its own cursor:
    `playseen`, identical semantics to `wakeseen` for identical reasons.
    """
    deadline = time.time() + (WATCH_TIMEOUT if wait else 0)
    while True:
        turns = read_turns()
        n = len(turns)
        cur = turns_gen(turns)
        wake = read_wake() if wakeseen is not None else None
        if wake is not None and wake["id"] == wakeseen:
            wake = None
        play = read_play() if playseen is not None else None
        if play is not None and play["id"] == playseen:
            play = None
        # A gen the client holds that no longer matches means the list was
        # rewritten under its cursor. The one benign mismatch is a client that
        # has seen nothing at all (empty gen, cursor at zero): its cursor is
        # trivially valid in any incarnation, so delivery stays incremental.
        if gen is not None and gen != cur and not (gen == "" and not since):
            out = {"n": n, "gen": cur, "turns": turns, "reset": True}
            if wake is not None:
                out["wake"] = wake
            if play is not None:
                out["play"] = play
            return out
        if since is None or since > n:
            since = n
        if n > since or wake is not None or play is not None:
            out = {"n": n, "gen": cur, "turns": turns[since:]}
            if wake is not None:
                out["wake"] = wake
            if play is not None:
                out["play"] = play
            return out
        if time.time() >= deadline:
            return {"n": n, "gen": cur, "turns": []}
        time.sleep(0.5)


def _suffix_for(ctype):
    """Chrome records webm/opus, iOS Safari mp4/aac — ffmpeg wants a hint."""
    if "mp4" in ctype or "aac" in ctype:
        return ".mp4"
    if "ogg" in ctype:
        return ".ogg"
    return ".webm"


def apply_whisper_fixes(text):
    """Speech-recognition rewrites (WHISPER_FIXES in the config), applied the
    moment a transcript is born. They used to be applied later, by
    `crab remote --voice` — after the raw transcript had already been shown to
    the phone — so the User: line stored in the conversation differed from the
    text the phone remembered, and the phone's own-turn filter let the turn
    echo back onto the screen as if it had been said elsewhere. One canonical
    transcript, fixed once, seen identically by the phone, the conversation
    file, and the prompt."""
    if not WHISPER_FIXES or not text:
        return text
    try:
        r = subprocess.run(["sed", "-E", WHISPER_FIXES], input=text.encode(),
                           capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return text
    if r.returncode != 0:
        return text
    fixed = " ".join(r.stdout.decode("utf-8", "replace").split()).strip()
    return fixed or text


# Whisper invents these out of room tone. "help" is the one that has actually
# bitten — a quiet clip comes back as a single frightened word nobody said.
SILENCE_WORDS = {
    "help", "help me", "you", "thank you", "thanks", "thanks for watching",
    "bye", "okay", "oh", "hmm", "mm", "yeah", "so", "uh", "um", "hi",
    "thank you for watching", "please subscribe", "the", "and", "silence",
}


def _wav_rms(path):
    """Loudness of a 16 kHz mono s16le wav, 0..32768. Silence sits near zero."""
    try:
        import array
        data = Path(path).read_bytes()[44:]
        if len(data) < 2:
            return 0.0
        a = array.array("h")
        a.frombytes(data[: len(data) - (len(data) % 2)])
        if not a:
            return 0.0
        return (sum(float(s) * s for s in a) / len(a)) ** 0.5
    except Exception:
        return None


def is_hallucinated_silence(text, wav):
    """True when a short, contentless transcript came off near-silent audio."""
    stripped = text.lower().strip(" .,!?…\"'")
    if not stripped:
        return False
    if len(stripped.split()) > 3:
        return False
    if stripped not in SILENCE_WORDS:
        return False
    rms = _wav_rms(wav)
    return rms is not None and rms < 350.0


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
        if is_hallucinated_silence(text, wav):
            text = ""
        return apply_whisper_fixes(text), None
    finally:
        for f in (raw, wav):
            f.unlink(missing_ok=True)


def _wav_seconds(path):
    """16 kHz mono s16le: 32000 bytes a second, minus the 44-byte header."""
    try:
        return max(0.0, (os.path.getsize(path) - 44) / 32000.0)
    except OSError:
        return 0.0


def _silences(wav):
    """Times (seconds) where a pause starts, so segments never cut mid-word."""
    r = run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(wav),
             "-af", "silencedetect=n=-35dB:d=0.35", "-f", "null", "-"])
    out = r.stderr.decode("utf-8", "replace")
    return [float(m) for m in re.findall(r"silence_start:\s*([0-9.]+)", out)]


class SttSession:
    """Incremental speech-to-text over a recording that is still happening.

    The phone uploads its MediaRecorder output in slices while you are still
    talking, so by the time the button is released almost all of the audio has
    already crossed the wire *and* been decoded. Only the tail is left.

    Slices after the first carry no container header, so they are only
    meaningful appended to the ones before them — the accumulated file is
    re-decoded each time (cheap, ~30 ms) and whisper is then run on just the
    part that has not been transcribed yet. Segment boundaries are placed at
    detected pauses rather than at slice boundaries: cutting mid-word costs
    more accuracy than waiting one more slice costs latency.
    """

    TTL = 600  # seconds; a session the phone abandoned is swept on next use

    def __init__(self, sid, suffix):
        self.sid = sid
        tmp = Path(tempfile.gettempdir())
        self.raw = tmp / f"deskcrab-stream-{sid}{suffix}"
        self.wav = tmp / f"deskcrab-stream-{sid}.wav"
        self.parts = []
        self.consumed = 0.0
        self.touched = time.time()
        self.lock = threading.Lock()
        self.raw.write_bytes(b"")

    def append(self, blob):
        with self.lock:
            self.touched = time.time()
            with open(self.raw, "ab") as f:
                f.write(blob)

    def advance(self, final=False):
        """Decode what has arrived and transcribe everything that has settled."""
        with self.lock:
            self.touched = time.time()
            if not self.raw.stat().st_size:
                return
            r = run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(self.raw),
                     "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                     str(self.wav)])
            if r.returncode != 0 or not self.wav.exists():
                return
            total = _wav_seconds(self.wav)
            if final:
                cut = total
            else:
                # Only pauses comfortably inside the audio are candidates: the
                # trailing silence of a slice is usually just the gap before
                # the next word, not the end of a phrase.
                pauses = [s for s in _silences(self.wav)
                          if s > self.consumed + 1.0 and s < total - 0.4]
                if not pauses:
                    return
                cut = pauses[-1]
            if cut - self.consumed < 0.4:
                return
            text = self._decode(self.consumed, cut - self.consumed)
            self.consumed = cut
            if text:
                self.parts.append(text)

    def _decode(self, start, dur):
        seg = self.wav.with_name(self.wav.stem + f"-{int(start * 100)}.wav")
        try:
            r = run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(self.wav),
                     "-ss", f"{start:.2f}", "-t", f"{dur:.2f}", str(seg)])
            if r.returncode != 0 or not seg.exists() or not seg.stat().st_size:
                return ""
            r = run(["whisper-cli", "-m", WHISPER_MODEL, "-f", str(seg),
                     "-nt", "-np"])
            if r.returncode != 0:
                return ""
            text = " ".join(r.stdout.decode("utf-8", "replace").split()).strip()
            if text.lower() in ("[blank_audio]", "(silence)", "[silence]", "."):
                return ""
            if is_hallucinated_silence(text, seg):
                return ""
            return text
        finally:
            seg.unlink(missing_ok=True)

    def transcript(self):
        return " ".join(p for p in self.parts if p).strip()

    def close(self):
        for f in (self.raw, self.wav):
            f.unlink(missing_ok=True)


STT_SESSIONS = {}
STT_LOCK = threading.Lock()


def stt_session(sid, suffix, create=False):
    with STT_LOCK:
        for dead in [k for k, v in STT_SESSIONS.items()
                     if time.time() - v.touched > SttSession.TTL]:
            STT_SESSIONS.pop(dead).close()
        s = STT_SESSIONS.get(sid)
        if s is None and create:
            s = STT_SESSIONS[sid] = SttSession(sid, suffix)
        return s


class Speaker:
    """Voices text blocks as they stream in, one at a time and in order.

    The desktop speaks every text block through piper while the turn is still
    running; the phone gets the same thing as a series of opus clips. Synthesis
    runs on its own thread so tailing the log never blocks, and strictly
    sequentially — a reply spoken out of order is worse than one spoken late.
    """

    def __init__(self, emit, turn=None):
        self.emit = emit
        self.turn = turn  # so /stop can reach a synthesis in flight (rule 47)
        self.queue = queue.Queue()
        self.voiced = 0  # clips actually emitted; the completion event offers
                         # the turn's own reply clip only when this stayed zero
        self.thread = threading.Thread(target=self._work, daemon=True)
        self.thread.start()

    def say(self, text):
        # A stopped turn's remaining sentences are not spoken (rule 47) — the
        # brake would otherwise fall silent for one clip and talk on.
        if self.turn is not None and self.turn.stopped:
            return
        self.queue.put(text)

    def _work(self):
        while True:
            text = self.queue.get()
            if text is None:
                return
            out = os.path.join(
                tempfile.gettempdir(), f"deskcrab-remote-{uuid.uuid4().hex}.opus")
            # A failure below used to vanish whole: the synth's stderr was
            # captured and discarded, the voice event was skipped, and the
            # turn stayed silent with no witness anywhere — two turns on
            # 2026-08-08 went that way and the cause could no longer be
            # established afterwards. A speech failure always leaves a line.
            try:
                r = run([CRAB_BIN, "synth", out, text], turn=self.turn)
            except TurnStopped:
                # The brake, not a failure: drain what is queued and wait for
                # the finish marker — silence here is chosen, not lost.
                continue
            except Exception as exc:  # noqa: BLE001 — a dead worker is silence
                print("speech: crab synth did not run for %d chars: %s"
                      % (len(text), exc), file=sys.stderr, flush=True)
                continue
            if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out):
                self.voiced += 1
                if self.voiced == 1:
                    turn_metric("first-audio", "%d chars" % len(text))
                self.emit("voice", {"text": text,
                                    "audio": "/audio/" + os.path.basename(out)})
            else:
                err = r.stderr.decode("utf-8", "replace").strip()[-300:]
                print("speech: synthesis produced nothing for %d chars (rc=%d)%s"
                      % (len(text), r.returncode, " — " + err if err else ""),
                      file=sys.stderr, flush=True)

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
    # With sentence streaming on, the registry walks the text deltas through
    # the shared chunker and the say callback feeds the Speaker one sentence
    # at a time — the same whitespace collapse the block path applies, and
    # crab synth strips markdown per clip exactly as it does per block. With
    # the flag off, chunker stays None and nothing below this line changes.
    chunker = None
    if speaker is not None and SENTENCE_STREAM:
        def _say_sentence(chunk):
            said = " ".join(chunk.split())
            if said:
                speaker.say(said)
        chunker = sentence_stream.BlockRegistry(_say_sentence)
    while not stop.is_set() and not os.path.exists(logpath):
        time.sleep(0.05)
    partial = ""
    try:
        with open(logpath, "r", errors="replace") as f:
            draining = False
            while True:
                if stop.is_set():
                    # The turn has ended; one last pass drains what landed
                    # since the previous read, then EOF ends the tail.
                    draining = True
                chunk = f.readline()
                if not chunk:
                    if draining:
                        return
                    time.sleep(0.05)
                    continue
                # readline() at EOF hands back a HALF-WRITTEN line, and the
                # rest arrives on the next call; neither half parses, and the
                # lines long enough to be split are exactly the assistant
                # blocks worth showing (the same bug crab-debug had). Hold the
                # fragment until its newline arrives — whole lines only.
                partial += chunk
                if not partial.endswith("\n"):
                    continue
                line, partial = partial.strip(), ""
                if not line.startswith("{"):
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # The streaming half, only when the flag armed a chunker: the
                # registry replays and dedups exactly as the desk's does, so
                # a re-emitted message or a re-read never speaks twice.
                if chunker is not None and d.get("type") == "stream_event":
                    chunker.stream_event(d.get("event") or {})
                    continue
                # NEVER stop at a result event: the usage-limit fallback
                # APPENDS a second claude run to this same log after the
                # refusal run's result, so a tail that returns at the first
                # result goes dark for the whole real turn — the phone shows
                # a spinner until the reply lands in one lump. The turn's end
                # is `stop`, set when `crab remote` exits; results are noise.
                if d.get("type") != "assistant" or "message" not in d:
                    continue
                # A limit refusal arrives shaped like a reply (a synthetic
                # assistant message). The fallback answers for real right
                # after it — the refusal is never shown or voiced.
                if d.get("is_api_error_message") or \
                        d.get("message", {}).get("model") == "<synthetic>":
                    continue
                for idx, block in enumerate(d["message"].get("content", [])):
                    kind = block.get("type")
                    if kind == "thinking":
                        thought = " ".join((block.get("thinking") or "").split())
                        if thought:
                            emit("thinking", thought[-400:])
                    elif kind == "tool_use":
                        seen_tools += 1
                        if seen_tools == 1:
                            turn_metric("first-tool",
                                        os.path.basename(logpath))
                        emit("tool", _tool_label(block))
                    elif kind == "text":
                        said = " ".join((block.get("text") or "").split())
                        said = said.split("---DISPLAY---")[0].strip()
                        if said:
                            # Not truncated: this block IS part of the reply on
                            # the phone, appended in order, not a status line.
                            # The text event stays per block in BOTH voice
                            # modes — the bubble and the client's own-turn
                            # match are built from it, and the flag is about
                            # clips, not text.
                            emit("text", said)
                            # Speak it now, exactly as the desktop's TTS
                            # streamer does — every text block gets a voice, not
                            # just the final one.
                            if speaker and chunker is None:
                                speaker.say(said)
                        if chunker is not None:
                            # The sentences were voiced off the deltas as they
                            # completed; this voices only the unspoken tail,
                            # and marks the block so a re-emitted copy adds
                            # nothing.
                            chunker.close_text(d["message"].get("id"), idx,
                                               block.get("text") or "")
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


def ask(text, on_event=None, speaker=None, turn=None):
    """One turn through the real assistant. Returns the crab remote JSON.

    With on_event, progress is reported live while the turn runs. With speaker,
    each text block is also voiced as it arrives instead of only at the end.

    No --voice here: WHISPER_FIXES was already applied when the transcript was
    made, and --voice would apply it a second time — worse, to typed text too.
    The turn must store the text exactly as the phone knows it, or the phone
    cannot recognise its own turn coming back around in /watch.
    """
    # The turn's identity rides down to the runner (spec rule 52): crab remote
    # deletes its own mid-turn spool entry once it holds the lock, and the
    # mail reader skips entries naming the run's own turn.
    if on_event is None:
        env = dict(os.environ)
        if turn is not None:
            env["DESKCRAB_TURN_ID"] = turn.tid
        r = run([CRAB_BIN, "remote", text], turn=turn, env=env)
    else:
        # Under STATE_PREFIX, never a bare /tmp name: crab-debug follows
        # <prefix>-turn-*.log, and a scratch instance (the test suite) writing
        # to the LIVE prefix paints its canaries into the live debug view.
        logpath = f"{STATE_PREFIX}-turn-{uuid.uuid4().hex}.log"
        stop = threading.Event()
        watcher = threading.Thread(
            target=_progress_events, args=(logpath, stop, on_event, speaker),
            daemon=True,
        )
        watcher.start()
        env = dict(os.environ, DESKCRAB_REMOTE_LOG=logpath)
        if turn is not None:
            env["DESKCRAB_TURN_ID"] = turn.tid
        try:
            r = run([CRAB_BIN, "remote", text], turn=turn, env=env)
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
        sys.stderr.write("%s  %s\n" % (time.strftime("%H:%M:%S"),
                                       redact_secret(fmt % args)))

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

    def _send_file(self, f, ctype, extra=None):
        """A file, with single-range support (spec rule 18): browsers issue
        Range for audio elements and will not seek — some will not play —
        without it. A multi-range or unparseable header is answered with the
        whole file, which a server may always do."""
        try:
            data = f.read_bytes()
        except OSError:
            return self._send(404, "not found")
        headers = dict(extra or {})
        headers["Accept-Ranges"] = "bytes"
        m = re.match(r"bytes=(\d*)-(\d*)$",
                     (self.headers.get("Range") or "").strip())
        if not m or (not m.group(1) and not m.group(2)):
            return self._send(200, data, ctype, headers)
        if m.group(1):
            start = int(m.group(1))
            end = min(int(m.group(2)), len(data) - 1) if m.group(2) \
                else len(data) - 1
        else:  # bytes=-N: the final N bytes
            start = max(0, len(data) - int(m.group(2)))
            end = len(data) - 1
        if start >= len(data) or start > end:
            headers["Content-Range"] = "bytes */%d" % len(data)
            return self._send(416, b"", ctype, headers)
        headers["Content-Range"] = "bytes %d-%d/%d" % (start, end, len(data))
        return self._send(206, data[start:end + 1], ctype, headers)

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
        # keep_blank_values: "wakeseen=" (nothing played yet) is an opt-in that
        # must survive parsing — parse_qs silently drops empty values otherwise.
        query = parse_qs(url.query, keep_blank_values=True)
        query_key = (query.get("k") or [None])[0]
        path = url.path

        if path == "/health":
            # `busy` is deliberately unauthenticated: it carries no content,
            # only whether a turn is in flight, and a restarter needs to be
            # able to ask without holding the secret.
            return self._json(200, {"ok": True, "name": NAME,
                                    "busy": turns_in_flight(),
                                    "draining": _DRAINING.is_set()})

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

        if path == "/context":
            return self._json(200, read_context(), extra)

        if path == "/push/key":
            # The VAPID public key the browser subscribes against. Generated
            # once on first ask and kept forever — rotating it would orphan
            # every existing subscription.
            if _webpush is None:
                return self._json(501, {"error": "push unavailable: python-cryptography is not installed"}, extra)
            return self._json(200, {"key": _webpush.vapid_keys()[1]}, extra)

        # The token ledger's views (specs/metrics.md rules 21-23): same
        # process, same port, same auth as every other route. The data route
        # ships hour buckets, never raw records, so months of ledger stay a
        # cheap load and every filter is a client-side re-sum.
        if path == "/metrics":
            return self._send(200, (WEBAPP_DIR / "metrics.html").read_bytes(),
                              "text/html; charset=utf-8", extra)
        if path == "/metrics/data":
            if not METRICS_DIR:
                return self._json(501, {"error": "metrics are switched off"},
                                  extra)
            raw = (query.get("days") or ["7"])[0]
            try:
                days = max(1, min(366, int(raw)))
            except ValueError:
                days = 7
            try:
                doc = token_ledger.aggregate(METRICS_DIR, days)
            except Exception:
                doc = {"days": [], "buckets": []}
            return self._json(200, doc, extra)

        if path == "/watch":
            # Turns spoken at the laptop land in the same conversation file, so
            # the phone can follow along by watching it rather than being told.
            raw = (query.get("since") or [None])[0]
            try:
                since = int(raw) if raw is not None else None
            except ValueError:
                since = None
            wait = (query.get("wait") or ["1"])[0] != "0"
            wakeseen = (query.get("wakeseen") or [None])[0]
            playseen = (query.get("playseen") or [None])[0]
            gen = (query.get("gen") or [None])[0]
            # Only a wake-capable client (one that sends wakeseen) counts as
            # "connected": routing audio at a page too old to play it would
            # swallow the wake into silence on both devices.
            if wakeseen is not None:
                with contextlib.suppress(OSError):
                    Path(PHONE_SEEN).touch()
            return self._json(200, watch_turns(since, wait, wakeseen, gen,
                                               playseen), extra)

        if path.startswith("/turn/"):
            # Re-attach to an in-flight (or recently finished) turn: replay
            # the buffered events past the client's cursor, then follow live.
            tid = re.sub(r"[^a-f0-9]", "", os.path.basename(path).lower())[:64]
            t, _ = get_turn(tid)
            if t is None:
                return self._json(404, {"error": "unknown turn"}, extra)
            raw = (query.get("from") or ["0"])[0]
            try:
                start = int(raw)
            except ValueError:
                start = 0
            return self._stream_turn(t, start)

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
        if path in ("/icon-192.png", "/icon-512.png", "/apple-touch-icon.png",
                    "/icon-maskable-192.png", "/icon-maskable-512.png"):
            name = path[1:]
            return self._send(200, (WEBAPP_DIR / name).read_bytes(),
                              "image/png", extra)
        if path.startswith("/img/"):
            f = IMAGES.get(os.path.basename(path))
            if f is None or not f.is_file():
                return self._send(404, "not found")
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            return self._send_file(f, ctype, extra)
        if path.startswith("/audio/"):
            name = os.path.basename(path)
            # Only ever serve this server's own generated replies.
            if not name.startswith("deskcrab-remote-") or not name.endswith(".opus"):
                return self._send(404, "not found")
            f = Path(tempfile.gettempdir()) / name
            if not f.exists():
                return self._send(404, "not found")
            return self._send_file(f, "audio/ogg", extra)
        if path.startswith("/media/"):
            f = MEDIA.get(os.path.basename(path))
            # Re-made at serving time, not only at hand-off: a file moved or
            # swapped since the pointer was read must not widen what the token
            # reaches (spec rule 35).
            try:
                f = f.resolve(strict=True) if f is not None else None
            except OSError:
                f = None
            if f is None or not f.is_file() \
                    or not f.is_relative_to(Path.home().resolve()):
                return self._send(404, "not found")
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            return self._send_file(f, ctype, extra)

        return self._send(404, "not found")

    def do_POST(self):
        if not self._authed():
            return self._send(404, "not found")
        url = urlparse(self.path)

        length = int(self.headers.get("Content-Length") or 0)
        # /stt/finish legitimately carries nothing — the audio already arrived
        # in slices while the user was still talking.
        empty_ok = url.path == "/stt/finish"
        if length > MAX_UPLOAD or (length <= 0 and not empty_ok):
            return self._json(400, {"error": "bad body length"})
        body = self.rfile.read(length) if length > 0 else b""

        if url.path in ("/stt/chunk", "/stt/finish"):
            q = parse_qs(url.query)
            sid = re.sub(r"[^a-f0-9]", "", (q.get("s") or [""])[0])[:32]
            if not sid:
                return self._json(400, {"error": "bad session"})
            ctype = self.headers.get("X-Audio-Type", "audio/webm")
            final = url.path == "/stt/finish"
            s = stt_session(sid, _suffix_for(ctype), create=not final)
            if s is None:
                return self._json(200, {"error": "unknown session"})
            if body:
                s.append(body)
            # Non-final slices advance opportunistically: if the audio has not
            # reached a pause yet there is simply nothing to transcribe, and
            # saying so costs nothing.
            s.advance(final=final)
            if not final:
                return self._json(200, {"partial": s.transcript()})
            text = apply_whisper_fixes(s.transcript())
            with STT_LOCK:
                STT_SESSIONS.pop(sid, None)
            s.close()
            if not text:
                return self._json(200, {"error": "no speech detected"})
            return self._json(200, {"transcript": text})

        if url.path == "/played":
            # A playback report (spec rules 44-46): what the phone's audio
            # element actually did with a turn's clip. Recorded beside the
            # synth stamps in the metrics log, and consulted by the silence
            # alarm. Best-effort by design on the client, so the answer here
            # is never load-bearing.
            try:
                doc = json.loads(body.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            tid = re.sub(r"[^a-f0-9]", "",
                         str(doc.get("turn", "")).lower())[:64]
            event = str(doc.get("event", ""))
            clip = str(doc.get("clip", ""))[:16]
            detail = " ".join(str(doc.get("detail", "")).split())[:120]
            if not tid or event not in ("requested", "started", "completed",
                                        "error"):
                return self._json(400, {"error": "bad report"})
            st = playback_state(tid)
            with PLAYBACK_LOCK:
                PLAY_CAPABLE[0] = True
                st["last_report"] = time.time()
                # Per-clip truth (rules 39 and 46a): keep the FURTHEST state
                # each clip reached, so a late or repeated "requested" never
                # walks a heard clip back to unheard.
                rank = {"requested": 1, "started": 2, "completed": 3,
                        "error": 3}
                # One failure, one line (rule 44a): a dead source signals
                # twice — the media error and the rejection behind it — and
                # 8 of one day's 38 play-errors were the second report of a
                # failure already counted. The duplicate still updates the
                # state below (a stop said twice must still stand the alarm
                # down); only its metrics line is dropped.
                dup_error = (event == "error"
                             and st["clips"].get(clip) == "error")
                if rank.get(event, 0) > rank.get(st["clips"].get(clip), 0):
                    st["clips"][clip] = event
                if event == "started":
                    st["started"] = True
                elif event == "error":
                    if detail.startswith("stopped"):
                        st["stopped"] = True
                    st["last_error"] = (detail or "error") + " at clip " + clip
            if not dup_error:
                turn_metric("play-" + event,
                            "turn %s clip %s%s"
                            % (tid[:8], clip, " — " + detail if detail else ""))
            return self._json(200, {"ok": True})

        if url.path == "/stop":
            # The brake (spec rules 47-48): genuinely kill a turn in flight —
            # the crab remote run and any synthesis beside it — releasing the
            # one-mind lock with the process that held it. The turn's own
            # thread emits the stopped completion event; this answer only
            # says the kill is in motion.
            try:
                doc = json.loads(body.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            tid = re.sub(r"[^a-f0-9]", "",
                         str(doc.get("turn", "")).lower())[:64]
            t, _ = get_turn(tid)
            if t is None:
                return self._json(404, {"error": "unknown turn"})
            if not stop_turn(t):
                return self._json(200, {"ok": True, "done": True})
            turn_metric("turn-stop", "turn %s by hand" % tid[:8])
            return self._json(200, {"ok": True, "stopped": True})

        if url.path in ("/push/subscribe", "/push/unsubscribe"):
            # The browser's PushSubscription, stored so `crab notify` can reach
            # this phone with the page closed. Idempotent by endpoint: the page
            # re-posts its subscription on every load and the store never grows
            # a duplicate.
            if _webpush is None:
                return self._json(501, {"error": "push unavailable: python-cryptography is not installed"})
            try:
                doc = json.loads(body.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            if url.path == "/push/unsubscribe":
                removed, left = _webpush.remove_subscription(str(doc.get("endpoint", "")))
                return self._json(200, {"ok": True, "removed": removed, "stored": left})
            if not _webpush.valid_subscription(doc):
                return self._json(400, {"error": "not a valid PushSubscription"})
            return self._json(200, {"ok": True, "stored": _webpush.add_subscription(doc)})

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
            tid = _clean_tid((parse_qs(url.query).get("turn") or [""])[0])
        elif url.path == "/say":
            try:
                doc = json.loads(body.decode("utf-8"))
                text = doc.get("text", "").strip()
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            if not text:
                return self._json(200, {"error": "empty message"})
            tid = _clean_tid(doc.get("turn"))
        else:
            return self._send(404, "not found")

        # The answer is streamed, not returned in one lump: the desktop client
        # shows thinking and tool use as it happens and the phone should too.
        # Plain chunked SSE over the same POST — no second connection to
        # authenticate, correlate, and clean up.
        #
        # The turn itself runs on its own thread, feeding a buffer; this
        # connection merely tails the buffer. If the hotspot drops mid-turn the
        # turn carries on, and the client reconnects to /turn/<id>?from=<n> for
        # the rest. The id comes from the client so a retried POST is
        # idempotent: same id -> attach to the running turn, never a second run.
        # While draining, a turn the imminent exit would kill must not start;
        # the client retries this POST (same id, backoff) against the fresh
        # server. An id already in flight attaches as ever — see above.
        turn, created = get_turn(tid, create=not _DRAINING.is_set())
        if turn is None:
            return self._json(503, {"error": "restarting — retry shortly"})
        if created:
            turn.emit("transcript", {"text": text})
            threading.Thread(target=run_turn, args=(turn, text),
                             daemon=True).start()
        return self._stream_turn(turn, 0)

    def _stream_turn(self, turn, start):
        """SSE-over-chunked: replay buffered events from `start`, then follow
        live until the turn is done. A write failure just ends this tail — the
        buffer, and the turn, live on."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def write(raw):
            try:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
                self.wfile.flush()
                return True
            except (BrokenPipeError, ConnectionResetError, ValueError, OSError):
                return False

        i = max(0, start)
        # The replay boundary and the voice ordinal (phone.md rule 39): every
        # voice event already buffered when this tail attached is a REPLAY,
        # and each replayed voice event carries the server's own playback
        # truth for that clip — reported started or completed means it played,
        # anything else means a re-attaching client still owes it a voice.
        # Clip indexes are the order voice events entered the buffer, which is
        # exactly how the client counts them.
        with turn.cond:
            attach_len = len(turn.events)
            voice_seen = sum(1 for ev in turn.events[:i]
                             if ev.get("kind") == "voice")
        while True:
            # Every bound on a legitimate run is far inside this: the
            # subprocess dies at TURN_TIMEOUT, the synthesiser join is shorter.
            # A buffer this old with no done event is a turn thread that hung
            # or died without reporting — and pinging it forever is exactly the
            # permanent "thinking…" the client cannot be asked to survive.
            # Rule 6: every turn ends in a completion event. give_up() takes
            # the cond itself, so it is called outside the block below.
            overdue = not turn.done and time.time() - turn.created > TURN_TIMEOUT + 180
            with turn.cond:
                if i >= len(turn.events) and not turn.done and not overdue:
                    turn.cond.wait(timeout=15)
                events = turn.events[i:]
                done = turn.done
            if not events and not done:
                if overdue:
                    turn.give_up("the turn stalled on the server and was given up on")
                    continue
                # Keepalive comment: without traffic a dead hotspot socket can
                # sit in ESTABLISHED forever and this thread would tail nothing
                # to nobody. The client ignores non-data frames.
                if not write(b": ping\n\n"):
                    return
                continue
            played = None
            for k, ev in enumerate(events):
                if ev.get("kind") == "voice":
                    if i + k < attach_len:
                        # A replayed clip: annotate with whether it was ever
                        # reported playing, so the client can give the tail
                        # that never sounded its voice instead of dropping
                        # the whole backlog by wall clock (the 00:40 loss).
                        if played is None:
                            st = playback_state(turn.tid)
                            with PLAYBACK_LOCK:
                                played = {k2 for k2, v in st["clips"].items()
                                          if v in ("started", "completed")}
                        ev = dict(ev, played=str(voice_seen) in played)
                    voice_seen += 1
                frame = f"data: {json.dumps(ev)}\n\n".encode("utf-8")
                if not write(frame):
                    return
            i += len(events)
            if done and i >= len(turn.events):
                break
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ValueError, OSError):
            pass
        return


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True
    _HTTPD[0] = httpd
    signal.signal(signal.SIGTERM, _on_sigterm)

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
        return
    # serve_forever only returns when the drain worker called shutdown().
    print("drained, exiting", flush=True)


if __name__ == "__main__":
    main()
