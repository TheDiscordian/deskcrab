#!/usr/bin/env python3
"""chess_mover: her chess move, seconds after the opponent's.

The resident mover behind specs/chessweb.md rule 16. The move path used to
book a wake into the single-session queue — the same lane as the user's own
conversation — so the person waiting at the board pushed her reply back every
time they talked to her, and each move rebuilt her entire prompt to pick one
chess move: two to five minutes per move, measured. This module answers a
position in-process instead. The hub owns detection (it knows the moment a
position becomes hers) and posting (it owns the store and the browser
broadcast); this class owns the slot in between: at most one position ever
being answered, the newest position always winning, and one minimal model
call — a tiny purpose-built prompt, none of deskcrab's prompt assembly — when
reflex memory has no answer.

The model invocation is the measured minimal shape from
tools/context-probe-results.md: no tools, the empty MCP config, no skills
catalogue, a two-line system prompt, a sterile cwd, auto-memory off. A failed
attempt walks the login chain within the call; a position whose every attempt
failed is re-offered by the hub's store poll on a cooldown, so a turn is
never silently lost.
"""

import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import chess

UCI_RE = re.compile(r"\b([a-h][1-8][a-h][1-8][qrbnQRBN]?)\b")

# The mover's prompt is deliberately tiny — that is what buys the seconds —
# but a move chosen by a voiceless prompt is a move the assistant did not
# make. The persona file is read once at import (a static string costs no
# latency) and prepended to the instructions; without one, the prompt is
# exactly the generic player it always was.
PERSONA_FILE = os.environ.get(
    "CHESS_PERSONA_FILE",
    str(Path.home() / ".local/share/deskcrab/chess-persona.md"))


def _persona():
    try:
        text = Path(PERSONA_FILE).read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    return text + "\n\n" if text else ""


SYSTEM_PROMPT = (_persona() +
                 "You are a strong chess player making a move in a live "
                 "game. Never leave a piece where the exchange on its square "
                 "loses material — count the attackers and the defenders "
                 "before you choose. Reply with your chosen move in UCI "
                 "notation (like e2e4 or e7e8q) and nothing else.")

# Rb6 on 2026-08-09 was played because it looked forcing; nobody counted who
# was looking at b6. The counting is the machine's job now, not a resolution:
# every legal move is run through a static exchange before the prompt is
# written, and the ones that lose material say so in the prompt.
PIECE_VALUE = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330,
               chess.ROOK: 500, chess.QUEEN: 900, chess.KING: 20000}


def _swap_off(board, square, side):
    """Material won by `side` capturing on `square`, least valuable attacker
    first, each side free to stop. Standard static exchange evaluation."""
    attackers = board.attackers(side, square)
    if not attackers:
        return 0
    victim = board.piece_at(square)
    if victim is None:
        return 0
    best = min(attackers, key=lambda s: PIECE_VALUE[board.piece_type_at(s)])
    captured = PIECE_VALUE[victim.piece_type]
    board.push(chess.Move(best, square))
    try:
        gain = captured - _swap_off(board, square, not side)
    finally:
        board.pop()
    return max(0, gain)


def material_loss(board, move):
    """Centipawns `move` hands the opponent by the exchange on its own
    destination square. 0 when the square is safe."""
    board.push(move)
    try:
        return _swap_off(board, move.to_square, board.turn)
    finally:
        board.pop()

# How long a posted (or stale-discarded) position stays claimed. Only an undo
# can bring the same position back inside this window, and the poll's resync
# path resets the mover outright on one, so this is a dedup horizon rather
# than a wait anyone experiences.
POSTED_TTL = 10.0


def _env_secs(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


def _retry_secs():
    """The cooldown after ONE failed round (all accounts tried, no move)."""
    return _env_secs("DESKCRAB_CHESS_MOVER_RETRY", "20")


def _retry_cap():
    """The ceiling the doubling cooldown grows to (chessweb.md rule 16e)."""
    return _env_secs("DESKCRAB_CHESS_MOVER_RETRY_CAP", "600")


def _max_fails():
    """Consecutive failed rounds before the position is stalled."""
    try:
        return int(os.environ.get("DESKCRAB_CHESS_MOVER_MAX_FAILS", "6"))
    except ValueError:
        return 6


def _stall_retry():
    """Seconds between probe rounds once stalled; 0 stops retrying outright.
    The probe is what lets a session limit that resets on the clock heal
    without anyone restarting the bridge."""
    return _env_secs("DESKCRAB_CHESS_MOVER_STALL_RETRY", "600")


# Output lines carrying one of these name the failure better than whatever
# the CLI happened to print last: on 2026-08-11 a settings-file warning on
# stderr masked "You've hit your session limit" on stdout in every logged
# failure, and the loop was diagnosed from the wrong line for half an hour.
_CAUSE_MARKERS = ("session limit", "usage limit", "rate limit", "not logged",
                  "please run /login", "overloaded", "credit balance",
                  "api error", "billing")


class Mover:
    """One background thread, one slot. submit() places the newest position
    in the slot and kills any in-flight call it supersedes; the thread drains
    the slot, makes the call, and hands the validated answer back through
    `play` — the hub's posting callback, which re-reads the store under its
    own lock before anything is written (chessweb.md rule 16d)."""

    def __init__(self, play, log=print, metric=lambda stage, detail="": None,
                 alert=None):
        self.play = play          # play(job, chess.Move) -> bool: it landed
        self.log = log
        self.alert = alert or log  # failures go here: loud, journal-visible
        self.metric = metric
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.slot = None          # the newest unanswered position (a job)
        self.inflight = None      # key of the job being answered right now
        self.proc = None          # the live model call, killable
        self.resolved = {}        # key -> (outcome, epoch): the dedup memory
        self.fails = {}           # key -> consecutive failed rounds
        self.fail_why = {}        # key -> the last round's best failure cause
        threading.Thread(target=self._run, daemon=True,
                         name="chess-mover").start()

    # -- the gate ----------------------------------------------------------
    def claim(self, key):
        """May this position be worked on now? False while it is already
        pending, in flight, freshly answered, or cooling down after a
        failure — which is what lets the store poll re-offer the position
        every tick without the mover ever answering it twice. The failure
        cooldown DOUBLES per consecutive failed round up to the cap, and a
        position past the failure cap is stalled: claimable only once per
        stall-retry window (never, when that is 0), so a dead login chain
        costs probes, not a call-burning loop (chessweb.md rule 16e)."""
        now = time.time()
        with self.lock:
            if self.slot is not None and self.slot["key"] == key:
                return False
            if self.inflight == key:
                return False
            got = self.resolved.get(key)
            if got is not None:
                outcome, at = got
                if outcome == "failed":
                    n = self.fails.get(key, 1)
                    if n >= _max_fails():
                        probe = _stall_retry()
                        if probe <= 0 or now - at < probe:
                            return False
                    else:
                        ttl = min(_retry_secs() * (2 ** max(0, n - 1)),
                                  _retry_cap())
                        if now - at < ttl:
                            return False
                elif now - at < POSTED_TTL:
                    return False
            return True

    def resolve(self, key, outcome):
        """Record an outcome decided outside the thread (a reflex hit)."""
        with self.lock:
            self._resolve_locked(key, outcome)

    def _resolve_locked(self, key, outcome):
        """Record an outcome; returns the consecutive failed-round count
        (0 after anything but a failure)."""
        self.resolved[key] = (outcome, time.time())
        if outcome == "failed":
            self.fails[key] = self.fails.get(key, 0) + 1
        else:
            self.fails.pop(key, None)
            self.fail_why.pop(key, None)
        if len(self.resolved) > 64:
            for k in sorted(self.resolved,
                            key=lambda k: self.resolved[k][1])[:32]:
                del self.resolved[k]
                self.fails.pop(k, None)
                self.fail_why.pop(k, None)
        return self.fails.get(key, 0)

    def failure_state(self, key):
        """(consecutive failed rounds, stalled?, last cause) — what the
        banner needs to stop calling a dead think 'thinking'."""
        with self.lock:
            n = self.fails.get(key, 0)
            return n, n >= _max_fails(), self.fail_why.get(key, "")

    def submit(self, job):
        """The newest position to answer. A job carries key, gid, ply, fen,
        side, opponent, history, note, effort, t0. Replaces whatever was
        pending and abandons an in-flight call for any other position."""
        with self.lock:
            if self.slot is not None and self.slot["key"] == job["key"]:
                return
            if self.inflight == job["key"]:
                return
            self.slot = job
            if self.inflight is not None:
                self._abandon_locked()
            self.cond.notify()

    def reset(self):
        """History rewrote on disk (an undo, a replaced game): every claim
        and outcome is void, and an in-flight think is about a board that no
        longer exists."""
        with self.lock:
            self.slot = None
            self.resolved.clear()
            self.fails.clear()
            self.fail_why.clear()
            self._abandon_locked()

    def _abandon_locked(self):
        if self.proc is not None:
            try:
                self.proc.kill()
            except OSError:
                pass

    def wait_idle(self, timeout=30.0):
        """Block until nothing is pending or in flight; for tests."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if self.slot is None and self.inflight is None:
                    return True
            time.sleep(0.05)
        return False

    # -- the thread --------------------------------------------------------
    def _run(self):
        while True:
            with self.lock:
                while self.slot is None:
                    self.cond.wait()
                job, self.slot = self.slot, None
                self.inflight = job["key"]
            try:
                outcome, why = self._answer(job)
            except Exception as e:  # a broken answer must never stop the loop
                self.alert(f"mover: {job['gid']} ply {job['ply']} "
                           f"failed unexpectedly: {e!r}")
                outcome, why = "failed", repr(e)
            fails = 0
            with self.lock:
                self.inflight = None
                self.proc = None
                if outcome:
                    fails = self._resolve_locked(job["key"], outcome)
                    if outcome == "failed":
                        self.fail_why[job["key"]] = (why or "")[:200]
            if outcome == "failed" and fails == _max_fails():
                self.metric("mover-stalled",
                            f"{job['gid']} ply {job['ply']} after "
                            f"{fails} rounds")
                probe = _stall_retry()
                self.alert(
                    f"mover: {job['gid']} ply {job['ply']} STALLED — "
                    f"{fails} consecutive rounds failed, last cause: "
                    f"{why or 'unknown'}. "
                    + (f"Probing again every {probe:.0f}s."
                       if probe > 0 else "Not retrying again."))

    def _answer(self, job):
        """(outcome, why): outcome is None when superseded, otherwise
        posted/stale/failed; why carries the round's most telling failure
        cause when the outcome is failed."""
        board = chess.Board(job["fen"])
        prompt = self._prompt(job, board)
        effort = job.get("effort") or os.environ.get(
            "DESKCRAB_CHESS_MOVER_EFFORT", "medium")
        move = None
        last_why = ""
        for label, cmd, env in self._attempts(effort):
            t0 = time.time()
            self.metric("model-start",
                        f"{job['gid']} ply {job['ply']} effort {effort} "
                        f"{label}")
            out, why = self._call(cmd, env, prompt)
            dt = time.time() - t0
            if why == "superseded":
                self.metric("model-end",
                            f"{job['gid']} ply {job['ply']} {dt:.1f}s "
                            f"superseded")
                self.log(f"mover: {job['gid']} ply {job['ply']} superseded "
                         f"after {dt:.1f}s — answering the newer position")
                return None, None
            move = self._parse(board, out) if out else None
            outcome = "ok" if move else (why or "no-legal-move")
            self.metric("model-end",
                        f"{job['gid']} ply {job['ply']} {dt:.1f}s {outcome}")
            if move:
                break
            last_why = f"{label}: {outcome}"
            self.alert(f"mover: {job['gid']} ply {job['ply']} attempt "
                       f"{label} came back {outcome} after {dt:.1f}s")
        if move is None:
            self.alert(f"mover: {job['gid']} ply {job['ply']}: every attempt "
                       f"failed — last: {last_why or 'no attempts ran'}")
            return "failed", last_why
        return ("posted" if self.play(job, move) else "stale"), None

    # -- the call ----------------------------------------------------------
    def _attempts(self, effort):
        override = os.environ.get("DESKCRAB_CHESS_MOVER_CMD")
        if override:
            yield "stub", shlex.split(override), self._env(None)
            return
        for conf in self._accounts():
            label = "primary" if conf is None else Path(conf).name
            yield label, self._claude_cmd(effort), self._env(conf)

    @staticmethod
    def _accounts():
        """Login config dirs to try, the recorded default first; None names
        the primary login (no CLAUDE_CONFIG_DIR). The chain is
        specs/account-fallback.md's, read-only: rotating the durable default
        is the session machinery's call, never a chess move's."""
        chain = [None]
        for d in re.split(r"[:\s]+",
                          os.environ.get("CLAUDE_FALLBACK_CONFIG_DIR", "")):
            if d:
                # systemd's EnvironmentFile hands values through unexpanded
                # (the same trap _claude_cmd guards CLAUDE_BIN against): a
                # literal "$HOME/..." handed to CLAUDE_CONFIG_DIR names an
                # empty login that answers "Not logged in" while the real
                # account sits logged in (2026-08-11), and it never matches
                # the recorded default below, so the chain never rotates.
                chain.append(os.path.expanduser(os.path.expandvars(d)))
        default_file = os.environ.get("ACCOUNT_DEFAULT_FILE") or os.path.join(
            os.environ.get("XDG_DATA_HOME",
                           os.path.expanduser("~/.local/share")),
            "deskcrab", "account-default")
        try:
            with open(default_file) as fh:
                stored = fh.readline().split("\t")[0].strip()
        except OSError:
            stored = ""
        if stored:
            stored = os.path.expanduser(os.path.expandvars(stored))
        start = chain.index(stored) if stored in chain else 0
        return chain[start:] + chain[:start]

    @staticmethod
    def _claude_cmd(effort):
        # A conf-set CLAUDE_BIN can arrive with $HOME still in it: systemd's
        # EnvironmentFile hands values through unexpanded, where every shell
        # path expanded them on the way in.
        claude = os.environ.get("CLAUDE_BIN", "")
        if claude:
            claude = os.path.expanduser(os.path.expandvars(claude))
        if not claude or not os.path.exists(claude):
            claude = (shutil.which("claude")
                      or os.path.expanduser("~/.local/bin/claude"))
        model = (os.environ.get("DESKCRAB_CHESS_MOVER_MODEL")
                 or os.environ.get("CLAUDE_MODEL") or "sonnet")
        cmd = [claude, "-p", "--dangerously-skip-permissions",
               "--model", model, "--effort", effort,
               "--disable-slash-commands",
               "--system-prompt", SYSTEM_PROMPT]
        empty_mcp = Path(__file__).resolve().parent / "empty-mcp.json"
        if empty_mcp.is_file():
            # --tools "" is only safe behind the empty MCP config: without
            # it the CLI inlines every MCP schema instead of deferring them
            # (the 116k-token trap, tools/context-probe-results.md).
            cmd += ["--strict-mcp-config", "--mcp-config", str(empty_mcp),
                    "--tools", ""]
        return cmd

    @staticmethod
    def _env(conf):
        env = dict(os.environ)
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        for marker in ("CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION",
                       "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_ENTRYPOINT"):
            env.pop(marker, None)
        if conf is None:
            env.pop("CLAUDE_CONFIG_DIR", None)
        else:
            env["CLAUDE_CONFIG_DIR"] = conf
        return env

    @staticmethod
    def _sterile_cwd():
        """An empty directory with no repository above it: the CLI charges
        for everything it discovers from the cwd, and a chess move needs
        none of it."""
        base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
        d = os.path.join(base, "deskcrab-chess-mover")
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            return "/"
        return d

    def _call(self, cmd, env, prompt):
        """(stdout, why-it-failed). why is None on a clean exit and
        'superseded' when a newer position killed or outran the call."""
        try:
            timeout = float(os.environ.get("DESKCRAB_CHESS_MOVER_TIMEOUT",
                                           "90"))
        except ValueError:
            timeout = 90.0
        try:
            proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
                cwd=self._sterile_cwd(), env=env)
        except OSError as e:
            return "", f"spawn: {e}"
        with self.lock:
            if self.slot is not None:
                proc.kill()
                proc.wait()
                return "", "superseded"
            self.proc = proc
        why = None
        try:
            out, err = proc.communicate(prompt, timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            out, err = "", ""
            why = f"timeout-{timeout:.0f}s"
        with self.lock:
            self.proc = None
            if self.slot is not None:
                return out or "", "superseded"
        if why:
            return "", why
        if proc.returncode != 0:
            # The most telling line, not the last one: on 2026-08-11 a
            # settings-file warning was stderr's last line on every call,
            # and "You've hit your session limit" sat unlogged on stdout.
            lines = [ln.strip()
                     for ln in f"{err or ''}\n{out or ''}".splitlines()
                     if ln.strip()]
            detail = next((ln for ln in lines
                           if any(m in ln.lower()
                                  for m in _CAUSE_MARKERS)),
                          lines[-1] if lines else "")
            return out or "", f"exit-{proc.returncode}: {detail[:200]}"
        return out or "", None

    # -- the words ---------------------------------------------------------
    @staticmethod
    def _prompt(job, board):
        safe, hangs = [], []
        for m in board.legal_moves:
            loss = material_loss(board, m)
            label = f"{board.san(m)} ({m.uci()})"
            (safe if loss <= 0 else hangs).append(
                label if loss <= 0 else f"{label} loses {loss}")
        lines = [f"You are playing {job['side']} against {job['opponent']} "
                 f"(game {job['gid']}, ply {job['ply']}).",
                 f"Position (FEN): {job['fen']}",
                 f"Moves so far: {job['history']}",
                 f"Legal moves that do not lose material on their own "
                 f"square: {', '.join(safe) or 'none'}"]
        if hangs:
            lines.append("Legal but the exchange on the destination square "
                         "loses material (centipawns) — play one only with a "
                         f"concrete reason: {', '.join(hangs)}")
        note = (job.get("note") or "").strip()
        if note:
            lines.append(note)
        lines.append("Answer with one legal move in UCI notation, "
                     "nothing else.")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _parse(board, text):
        """The move in the reply, or None. UCI tokens first — the reply was
        asked for in UCI, and the last one wins in case the model narrated
        its way to the answer — then SAN as the fallback it sometimes is."""
        move = None
        for tok in UCI_RE.findall(text):
            try:
                m = chess.Move.from_uci(tok.lower())
            except chess.InvalidMoveError:
                continue
            if m in board.legal_moves:
                move = m
        if move is not None:
            return move
        for tok in reversed(text.split()):
            tok = tok.strip(".,!?:;()[]{}\"'`*")
            if not tok:
                continue
            try:
                return board.parse_san(tok)
            except ValueError:
                continue
        return None
