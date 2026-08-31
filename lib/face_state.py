"""The face-state broker: one small local owner of what Beatrice's face is doing.

Three surfaces read the same face — the conversation portrait window, the chess
table, and the OpenRSC spectator — and none of them may invent a mood. This
module is the single place face state lives, and the only writers are:

  - her own explicit hand (`crab face ...`), in the same turn that forms
    her words;
  - trustworthy runtime facts (turn lifecycle, TTS clip playback, chess
    thinking, spectator pause) as the *activity* layer;
  - a tiny, inspectable, disableable allowlist of confirmed events.

Nothing here reads transcripts, sentiment, chess evaluation, or hit points.
A classifier given only the delivered words must not be able to reconstruct
the expression timeline — that property is the point, not an accident.

State is layered rather than flattened (specs/face.md rule 3):

  1. activity   — presence facts: resting, listening, considering, speaking,
                  chess, openrsc-live, openrsc-paused, unavailable;
  2. expression — one expression record from the authored family, with its
                  source and the recovery condition chosen when it was set;
  3. mood       — a standing, slow-moving baseline inferred out of band from
                  the conversation she is actually having (2026-08-30
                  amendment: the user asked for automatic expression; the
                  old authored-only ban is deliberately superseded);
  4. speech     — transient viseme cue tracks tied to real TTS clips;
  5. recovery   — explicit (`crab face rest`) or the lifetime the record
                  was set with; mood decays on its own clock.

Expression records carry a source, and sources are ranked: her explicit
hand outranks the confirmed-event allowlist, which outranks the automatic
tier (per-sentence acting and the mood baseline). An automatic write NEVER
displaces an explicit or event record, always carries a bounded lifetime,
and is refused when its turn token is stale — a classification computed
for a turn that is already over must not repaint the face of the next one.

Transport: one unix-domain socket, JSON lines, request/reply, plus a `watch`
verb that streams every state change to a connected viewer. The two web
servers relay reads through their own auth boundaries; the socket itself
never leaves the machine.

Stdlib only, like every sibling in lib/.
"""

import json
import os
import socket
import socketserver
import sys
import threading
import time

STATE_PREFIX = os.environ.get("DESKCRAB_STATE_PREFIX", "/tmp/deskcrab")
SOCKET_PATH = os.environ.get("DESKCRAB_FACE_SOCKET",
                             STATE_PREFIX + "-face.sock")
STATE_PATH = os.environ.get("DESKCRAB_FACE_STATE",
                            STATE_PREFIX + "-face-state.json")

# The authored expression family (specs/face.md rule 4). `resting` is the
# absence of an expression record, not a member a caller sets.
EXPRESSIONS = ("attentive", "caught", "pleased", "annoyed",
               "focused", "tired", "startled")

# The presence/activity layer's whole vocabulary (specs/face.md rule 3).
ACTIVITIES = ("resting", "listening", "considering", "speaking",
              "chess", "openrsc-live", "openrsc-paused", "unavailable")

# The compact viseme family the mouth cue tracks speak in
# (specs/face.md rule 20). `rest` is the expression's own mouth.
VISEMES = ("rest", "slight", "open", "wide", "round", "teeth")

# The event allowlist (specs/face.md rule 17): confirmed event -> expression.
# Inspectable here, disableable via DESKCRAB_FACE_EVENTS (a comma list of the
# events that remain enabled; empty string disables them all).
EVENT_MAP = {
    "game-win": "pleased",
    "failed-action": "annoyed",
    "player-message": "attentive",
    "quest-message": "attentive",
    "combat-start": "focused",
}
_ENABLED = os.environ.get(
    "DESKCRAB_FACE_EVENTS",
    "game-win,failed-action,player-message,quest-message,combat-start")
ENABLED_EVENTS = {e.strip() for e in _ENABLED.split(",") if e.strip()}

# An event-sourced expression never outstays its welcome (rule 17): it always
# carries a bounded lifetime, so a mood is never fabricated into permanence.
EVENT_EXPRESSION_SECONDS = float(
    os.environ.get("DESKCRAB_FACE_EVENT_SECONDS", "60"))
# A failed click is a flinch, not a minute-long emotional baseline. Keep the
# shared lifetime for meaningful arrivals and completions while letting a
# routine mechanical refusal recover promptly.
FAILED_ACTION_SECONDS = float(
    os.environ.get("DESKCRAB_FACE_FAILED_ACTION_SECONDS", "8"))
EVENT_LIFETIMES = {"failed-action": FAILED_ACTION_SECONDS}

# Expression sources, ranked (specs/face.md rule 16 as amended 2026-08-30):
# her explicit hand > the confirmed-event allowlist > the automatic tier.
# A new record lands only when its rank is at least the standing record's.
SOURCE_RANK = {"explicit": 3, "event": 2, "auto": 1}

# The automatic tier's bounded lifetimes. A per-sentence flourish carries the
# clip's own length from the streamer; anything automatic that arrives
# without a lifetime gets this one.
AUTO_EXPRESSION_SECONDS = float(
    os.environ.get("DESKCRAB_FACE_AUTO_SECONDS", "45"))

# The mood baseline (2026-08-30 amendment): a standing emotional signal the
# out-of-band updater maintains from the conversation and her activity, so
# the face carries continuity between turns instead of classifying each
# spoken line in isolation. It decays on its own — an unrefreshed mood ends.
MOODS = ("pleased", "annoyed", "tired", "focused", "attentive")
MOOD_SECONDS = float(os.environ.get("DESKCRAB_FACE_MOOD_SECONDS", "900"))

# Deterministic presence→expression defaults, used only when nothing above
# them stands: trustworthy runtime facts, a fixed public table, no model.
# Disable with an empty DESKCRAB_FACE_ACTIVITY_EXPRESSIONS.
_ACT_DEFAULT = "listening=attentive,considering=focused,chess=focused"
ACTIVITY_EXPRESSIONS = {}
for _pair in os.environ.get("DESKCRAB_FACE_ACTIVITY_EXPRESSIONS",
                            _ACT_DEFAULT).split(","):
    if "=" in _pair:
        _k, _v = _pair.split("=", 1)
        if _k.strip() in ACTIVITIES and _v.strip() in EXPRESSIONS:
            ACTIVITY_EXPRESSIONS[_k.strip()] = _v.strip()

# Per-sentence acting (2026-08-30 amendment): immediate emotion — surprise
# above all — must land WITH the sentence, not smoothed into the mood. This
# is a fixed, inspectable table over the words she herself wrote and is
# about to speak: her own punctuation and interjections are her act, not an
# inference about her. First match wins; no match means no flourish.
# Disable with DESKCRAB_FACE_SENTENCE_CUES=0.
SENTENCE_CUES = (
    (r"(?:\?!|!\?)", "startled"),
    (r"(?i)\b(?:whoa|woah|wow|what on earth|good grief|yikes)\b", "startled"),
    (r"(?i)\b(?:ugh|argh|tsk|damn it|for goodness)\b", "annoyed"),
    (r"(?i)\b(?:ha|haha|hah|lovely|wonderful|delightful|hooray|yay)\b!",
     "pleased"),
    (r"(?i)^(?:oh|oh no|oh dear)\b.*!$", "startled"),
    (r"(?i)\b(?:hm+|hmm)\b\.*$", "focused"),
)
SENTENCE_CUES_ENABLED = os.environ.get(
    "DESKCRAB_FACE_SENTENCE_CUES", "1").strip() not in ("0", "")


def sentence_cue(text):
    """The flourish this sentence carries, or None. A pure function of the
    words she is about to speak — the same sentence always acts the same."""
    if not SENTENCE_CUES_ENABLED or not text:
        return None
    import re
    for pattern, name in SENTENCE_CUES:
        try:
            if re.search(pattern, text.strip()):
                return name
        except re.error:
            continue
    return None


def _now():
    return time.time()


def _one_line(value, limit):
    """Bounded state text: useful context, never a multiline prompt splice."""
    return " ".join(str(value or "").split())[:limit]


def _recover_mood_provenance(mood):
    """Recover subject, origin, and turn reference from the updater record.

    Saved mood records made without provenance still have a precise set time.
    A matching updater-log transition within two minutes is evidence; the
    mechanism's own name is not.  No match remains explicitly unavailable.
    """
    try:
        with open(STATE_PREFIX + "-face-auto.log", errors="replace") as fh:
            lines = fh.readlines()[-200:]
        target = float(mood.get("set_at", 0))
        marker = " -> %s from " % mood.get("name")
        for line in reversed(lines):
            stamp, message = line.rstrip("\n").split("\t", 1)
            if marker not in message or " (turn " not in message:
                continue
            source_and_ref = message.split(marker, 1)[1]
            origin, ref_tail = source_and_ref.split(" (turn ", 1)
            source_ref, detail = ref_tail.split("):", 1)
            subject = "source unavailable"
            detail = detail.strip()
            if detail.startswith("source "):
                subject = detail[7:].split(" — ", 1)[0].strip()
            logged = time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S"))
            if abs(logged - target) <= 120:
                return (_one_line(subject, 80), _one_line(origin, 80),
                        _one_line(source_ref, 120))
    except Exception:
        pass
    return "source unavailable", "origin unavailable", ""


# --------------------------------------------------------------------------
# Client side: everything the CLI, the streamer, and the web servers need.
# Every function here is best-effort and bounded — the face is company,
# never a dependency, and a dead broker must cost a caller nothing but the
# few milliseconds of one refused connect (specs/face.md rule 28).
# --------------------------------------------------------------------------

def send_cmd(cmd, timeout=2.0, socket_path=None):
    """One JSON request, one JSON reply. Returns the reply dict, or None
    when the broker is absent or unwilling — the caller decides whether
    that is worth saying out loud."""
    path = socket_path or SOCKET_PATH
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(path)
            s.sendall((json.dumps(cmd) + "\n").encode("utf-8"))
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf.decode("utf-8"))
    except Exception:
        return None


def get_state(timeout=1.0, socket_path=None):
    reply = send_cmd({"cmd": "state"}, timeout=timeout,
                     socket_path=socket_path)
    if reply and reply.get("ok"):
        return reply.get("state")
    return None


def wait_state(seq, timeout=25.0, socket_path=None):
    """Long-poll: answers when the broker's seq passes `seq`, or at the
    timeout with the unchanged state. None means no broker."""
    reply = send_cmd({"cmd": "wait", "seq": int(seq), "timeout": timeout},
                     timeout=timeout + 5.0, socket_path=socket_path)
    if reply and reply.get("ok"):
        return reply.get("state")
    return None


def ensure_broker(socket_path=None, spawn_timeout=3.0):
    """Make sure a broker is answering; spawn one detached if not.
    Returns True when a broker answers within the window."""
    if get_state(timeout=0.5, socket_path=socket_path) is not None:
        return True
    try:
        import subprocess
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "serve"],
            stdout=open(os.devnull, "wb"), stderr=subprocess.STDOUT,
            start_new_session=True, close_fds=True)
    except Exception:
        return False
    deadline = _now() + spawn_timeout
    while _now() < deadline:
        if get_state(timeout=0.5, socket_path=socket_path) is not None:
            return True
        time.sleep(0.05)
    return False


# --------------------------------------------------------------------------
# The broker itself.
# --------------------------------------------------------------------------

class Broker:
    def __init__(self, state_path=STATE_PATH):
        self.lock = threading.Condition()
        self.state_path = state_path
        self.seq = 0
        self.activity = "resting"
        self.activity_detail = ""
        self.expression = None   # {"name", "source", "set_at", "expires_at"}
        self.mood = None         # name, reason, source, origin/ref, times
        self.turn = ""           # the live turn's token; stale autos bounce
        self.clips = []          # [{"id","start","duration","cues"}...]
        self.watchers = 0
        self.started = _now()
        self._load()

    # ---- persistence: survives a broker restart, never a dependency ----
    def _load(self):
        try:
            with open(self.state_path) as fh:
                d = json.load(fh)
            self.seq = int(d.get("seq", 0))
            if d.get("activity") in ACTIVITIES:
                self.activity = d["activity"]
            self.activity_detail = str(d.get("activity_detail", ""))[:120]
            exp = d.get("expression")
            if isinstance(exp, dict) and exp.get("name") in EXPRESSIONS:
                self.expression = exp
            mood = d.get("mood")
            if isinstance(mood, dict) and mood.get("name") in MOODS:
                mood.setdefault("reason", "")
                legacy_origin = mood.get("source") if mood.get("source") in (
                    "desktop exchange", "phone exchange", "autonomous wake",
                    "completed exchange") else ""
                if legacy_origin:
                    mood["source"] = "source unavailable"
                    mood["origin"] = legacy_origin
                    mood.setdefault("source_ref", "")
                elif not mood.get("source"):
                    subject, origin, source_ref = _recover_mood_provenance(mood)
                    mood["source"] = subject
                    mood["origin"] = origin
                    mood["source_ref"] = source_ref
                else:
                    mood.setdefault("origin", "origin unavailable")
                    mood.setdefault("source_ref", "")
                self.mood = mood
            self.turn = str(d.get("turn", ""))[:80]
            clips = d.get("clips")
            if isinstance(clips, list):
                self.clips = clips
        except Exception:
            pass

    def _save(self):
        try:
            tmp = "%s.%d.tmp" % (self.state_path, os.getpid())
            with open(tmp, "w") as fh:
                json.dump({"seq": self.seq, "activity": self.activity,
                           "activity_detail": self.activity_detail,
                           "expression": self.expression,
                           "mood": self.mood, "turn": self.turn,
                           "clips": self.clips, "updated": _now()}, fh)
            os.replace(tmp, self.state_path)
        except Exception:
            pass

    def _bump(self):
        self.seq += 1
        self._save()
        self.lock.notify_all()

    # ---- reads ----
    def _live_clips(self, now):
        return [c for c in self.clips
                if c.get("start", 0) + c.get("duration", 0) > now - 0.5]

    def snapshot(self):
        now = _now()
        with self.lock:
            exp = self.expression
            if exp and exp.get("expires_at") and exp["expires_at"] <= now:
                # A lifetime chosen when the expression was set has passed:
                # recovery, not erasure by someone else's hand.
                self.expression = exp = None
                self._bump()
            if self.mood and self.mood.get("expires_at", 0) <= now:
                # An unrefreshed mood decays back to nothing on its own.
                self.mood = None
                self._bump()
            # The face shown is resolved HERE, once, so every surface agrees:
            # an expression record (explicit > event > auto) wins; then the
            # standing mood; then the deterministic activity default; then
            # resting. Lower layers keep standing underneath — an explicit
            # choice released early falls back to the mood, not to a blank.
            shown, source = "resting", ""
            if exp:
                shown, source = exp["name"], exp.get("source", "explicit")
            elif self.mood:
                shown, source = self.mood["name"], "mood"
            elif ACTIVITY_EXPRESSIONS.get(self.activity):
                shown, source = ACTIVITY_EXPRESSIONS[self.activity], "activity"
            clips = self._live_clips(now)
            speaking = any(c.get("start", 0) <= now
                           < c.get("start", 0) + c.get("duration", 0)
                           or c.get("start", 0) > now for c in clips)
            return {
                "seq": self.seq,
                "now": now,
                "activity": self.activity,
                "activity_detail": self.activity_detail,
                "expression": shown,
                "expression_source": source,
                "expression_set_at": (exp or {}).get("set_at"),
                "mood": (self.mood or {}).get("name", ""),
                "mood_reason": (self.mood or {}).get("reason", ""),
                "mood_source": (self.mood or {}).get("source", ""),
                "mood_origin": (self.mood or {}).get("origin", ""),
                "mood_source_ref": (self.mood or {}).get("source_ref", ""),
                "mood_set_at": (self.mood or {}).get("set_at"),
                "mood_expires_at": (self.mood or {}).get("expires_at"),
                "speaking": speaking,
                "clips": clips,
            }

    # ---- writes ----
    def set_activity(self, name, detail="", turn=None):
        if name not in ACTIVITIES:
            return {"ok": False, "error": "unknown activity %r" % name}
        with self.lock:
            # Activity never erases an authored expression (rule 18).
            self.activity = name
            self.activity_detail = str(detail or "")[:120]
            if turn:
                # The turn machinery names the turn it is working; automatic
                # results carrying an older token will be turned away.
                self.turn = str(turn)[:80]
            self._bump()
        return {"ok": True, "state": self.snapshot()}

    def _stale(self, turn):
        """True when an automatic write carries a token for a turn that is
        no longer the broker's current one. No token, or no registered
        turn, means nobody is competing — the write stands on its own."""
        return bool(turn) and bool(self.turn) and str(turn) != self.turn

    def set_expression(self, name, source="explicit", seconds=None,
                      turn=None):
        if name in ("resting", "rest", "none", ""):
            return self.rest()
        if name not in EXPRESSIONS:
            return {"ok": False,
                    "error": "unknown expression %r (family: %s)"
                             % (name, ", ".join(EXPRESSIONS))}
        if source not in SOURCE_RANK:
            return {"ok": False, "error": "unknown source %r" % source}
        if source == "event":
            seconds = seconds or EVENT_EXPRESSION_SECONDS
        if source == "auto":
            # The automatic tier is never permanent (2026-08-30 amendment).
            seconds = seconds or AUTO_EXPRESSION_SECONDS
        expires = (_now() + float(seconds)) if seconds else None
        with self.lock:
            if source == "auto" and self._stale(turn):
                return {"ok": True, "state": self.snapshot(),
                        "note": "stale turn — not applied"}
            cur = self.expression
            if cur and SOURCE_RANK[source] < SOURCE_RANK.get(
                    cur.get("source", "explicit"), 3):
                # A lower-ranked hand never displaces a higher one: her
                # explicit choice stands over events, and both stand over
                # anything automatic (rules 16-17 as amended).
                return {"ok": True, "state": self.snapshot(),
                        "note": "%s expression stands" % cur.get("source")}
            self.expression = {"name": name, "source": source,
                               "set_at": _now(), "expires_at": expires}
            self._bump()
        return {"ok": True, "state": self.snapshot()}

    def set_mood(self, name, turn=None, reason="", source="", origin="",
                 source_ref=""):
        """The standing baseline. `neutral` clears it; anything else must be
        in the mood family and lives MOOD_SECONDS from now unless refreshed.
        Display precedence is below every expression record, so a mood can
        never override her hand, an event, or a sentence's own acting."""
        if name in ("neutral", "none", ""):
            with self.lock:
                if self._stale(turn):
                    return {"ok": True, "state": self.snapshot(),
                            "note": "stale turn — not applied"}
                self.mood = None
                self._bump()
            return {"ok": True, "state": self.snapshot()}
        if name not in MOODS:
            return {"ok": False,
                    "error": "unknown mood %r (family: %s, or neutral)"
                             % (name, ", ".join(MOODS))}
        reason = _one_line(reason, 240)
        source = _one_line(source, 80) or "source unavailable"
        origin = _one_line(origin, 80) or "origin unavailable"
        source_ref = _one_line(source_ref, 120)
        with self.lock:
            if self._stale(turn):
                return {"ok": True, "state": self.snapshot(),
                        "note": "stale turn — not applied"}
            set_at = _now()
            self.mood = {"name": name, "reason": reason,
                         "source": source, "origin": origin,
                         "source_ref": source_ref,
                         "set_at": set_at,
                         "expires_at": set_at + MOOD_SECONDS}
            self._bump()
        return {"ok": True, "state": self.snapshot()}

    def rest(self):
        """Her explicit `rest` puts real composure back: it clears the
        expression record AND the standing mood, because an automatic
        baseline repainting the face seconds after she asked for rest would
        make her hand weaker than the machinery under it."""
        with self.lock:
            self.expression = None
            self.mood = None
            self._bump()
        return {"ok": True, "state": self.snapshot()}

    def event(self, name):
        if name not in EVENT_MAP:
            return {"ok": False, "error": "unknown event %r" % name}
        if name not in ENABLED_EVENTS:
            return {"ok": True, "note": "event mapping disabled",
                    "state": self.snapshot()}
        return self.set_expression(
            EVENT_MAP[name], source="event",
            seconds=EVENT_LIFETIMES.get(name, EVENT_EXPRESSION_SECONDS))

    def speak(self, clips):
        cleaned = []
        for c in clips if isinstance(clips, list) else []:
            try:
                cues = [[max(0.0, float(t)), str(v)]
                        for t, v in (c.get("cues") or [])
                        if str(v) in VISEMES]
                cleaned.append({
                    "id": str(c.get("id", ""))[:64],
                    "start": float(c["start"]),
                    "duration": max(0.0, float(c["duration"])),
                    "cues": cues[:400],
                })
            except Exception:
                continue
        if not cleaned:
            return {"ok": False, "error": "no usable clips"}
        with self.lock:
            now = _now()
            self.clips = (self._live_clips(now) + cleaned)[-24:]
            self._bump()
        return {"ok": True, "state": self.snapshot()}

    def speak_stop(self):
        """Stopped speech, playback failure, interruption, `shutup`: the
        mouth closes NOW and queued cues go with it (rule 23)."""
        with self.lock:
            self.clips = []
            self._bump()
        return {"ok": True, "state": self.snapshot()}

    def diag(self):
        snap = self.snapshot()
        with self.lock:
            snap.update({"watchers": self.watchers,
                         "socket": SOCKET_PATH,
                         "state_file": self.state_path,
                         "events_enabled": sorted(ENABLED_EVENTS),
                         "event_map": EVENT_MAP,
                         "event_lifetimes": {
                             name: EVENT_LIFETIMES.get(
                                 name, EVENT_EXPRESSION_SECONDS)
                             for name in EVENT_MAP
                         },
                         "expressions": list(EXPRESSIONS),
                         "activities": list(ACTIVITIES),
                         "visemes": list(VISEMES),
                         "moods": list(MOODS),
                         "mood_seconds": MOOD_SECONDS,
                         "mood_record": self.mood,
                         "turn": self.turn,
                         "source_rank": SOURCE_RANK,
                         "activity_expressions": ACTIVITY_EXPRESSIONS,
                         "sentence_cues": ([[p, n] for p, n in SENTENCE_CUES]
                                           if SENTENCE_CUES_ENABLED else []),
                         "uptime": _now() - self.started})
        return {"ok": True, "state": snap}

    def handle(self, cmd):
        verb = (cmd or {}).get("cmd", "")
        if verb == "state":
            return {"ok": True, "state": self.snapshot()}
        if verb == "wait":
            deadline = _now() + min(max(float(cmd.get("timeout", 25)), 0), 55)
            want = int(cmd.get("seq", -1))
            with self.lock:
                while self.seq <= want and _now() < deadline:
                    self.lock.wait(min(1.0, max(0.0, deadline - _now())))
            return {"ok": True, "state": self.snapshot()}
        if verb == "activity":
            return self.set_activity(cmd.get("name", ""),
                                     cmd.get("detail", ""),
                                     turn=cmd.get("turn"))
        if verb == "expression":
            return self.set_expression(cmd.get("name", ""),
                                       source=cmd.get("source", "explicit"),
                                       seconds=cmd.get("seconds"),
                                       turn=cmd.get("turn"))
        if verb == "mood":
            return self.set_mood(cmd.get("name", ""), turn=cmd.get("turn"),
                                 reason=cmd.get("reason", ""),
                                 source=cmd.get("source", ""),
                                 origin=cmd.get("origin", ""),
                                 source_ref=cmd.get("source_ref", ""))
        if verb == "rest":
            return self.rest()
        if verb == "event":
            return self.event(cmd.get("name", ""))
        if verb == "speak":
            return self.speak(cmd.get("clips"))
        if verb == "speak-stop":
            return self.speak_stop()
        if verb == "diag":
            return self.diag()
        return {"ok": False, "error": "unknown cmd %r" % verb}


class _Handler(socketserver.StreamRequestHandler):
    def handle(self):
        broker = self.server.broker
        try:
            line = self.rfile.readline(65536)
            if not line:
                return
            cmd = json.loads(line.decode("utf-8"))
        except Exception:
            self._reply({"ok": False, "error": "bad request"})
            return
        if cmd.get("cmd") == "watch":
            self._watch(broker)
            return
        self._reply(broker.handle(cmd))

    def _reply(self, obj):
        try:
            self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
            self.wfile.flush()
        except Exception:
            pass

    def _watch(self, broker):
        """Stream every change (and a keepalive heartbeat) until the viewer
        hangs up. The viewer joins the CURRENT state — never a replay of
        old motion (specs/face.md rule 24)."""
        with broker.lock:
            broker.watchers += 1
        last = -1
        try:
            while True:
                with broker.lock:
                    if broker.seq <= last:
                        broker.lock.wait(15.0)
                    seq = broker.seq
                snap = broker.snapshot()
                self.wfile.write((json.dumps(snap) + "\n").encode("utf-8"))
                self.wfile.flush()
                last = max(last, seq)
        except Exception:
            pass
        finally:
            with broker.lock:
                broker.watchers -= 1


class _Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = False


def serve():
    """Run the broker on SOCKET_PATH. Exactly one per socket: a second
    serve() against a living broker exits quietly, and a stale socket file
    (dead broker) is replaced."""
    if get_state(timeout=0.5) is not None:
        return 0
    try:
        os.unlink(SOCKET_PATH)
    except OSError:
        pass
    broker = Broker()
    try:
        srv = _Server(SOCKET_PATH, _Handler)
    except OSError as exc:
        sys.stderr.write("face broker cannot bind %s: %s\n"
                         % (SOCKET_PATH, exc))
        return 1
    os.chmod(SOCKET_PATH, 0o600)
    # A pid beside the socket, so a harness (or a hand) can end exactly this
    # broker without a pattern kill — the scoped-stop discipline of
    # specs/speech-output.md rule 21, kept here too.
    try:
        with open(SOCKET_PATH + ".pid", "w") as fh:
            fh.write(str(os.getpid()))
    except Exception:
        pass
    srv.broker = broker
    try:
        srv.serve_forever(poll_interval=0.5)
    finally:
        srv.server_close()
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(serve() if sys.argv[1:2] == ["serve"] else 2)
