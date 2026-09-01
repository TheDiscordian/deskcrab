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

import json
import fcntl
import hashlib
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
                 "before you choose. Choose exactly one token from the final "
                 "UCI whitelist in the prompt. Reply with that token in UCI "
                 "notation and nothing else.")

# Rb6 on 2026-08-09 was played because it looked forcing; nobody counted who
# was looking at b6. The counting is the machine's job now, not a resolution:
# every legal move is run through a static exchange before the prompt is
# written, and the ones that lose material say so in the prompt.
PIECE_VALUE = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330,
               chess.ROOK: 500, chess.QUEEN: 900, chess.KING: 20000}

PIECE_NAME = {chess.PAWN: "pawn", chess.KNIGHT: "knight",
              chess.BISHOP: "bishop", chess.ROOK: "rook",
              chess.QUEEN: "queen", chess.KING: "king"}

# A reply that is checkmate outranks every material number.
MATE_LOSS = 100000


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


def standing_losses(board, side=None):
    """The position-level sweep (chess-mover-amendment.md): pieces of
    `side`'s (default: the side to move) that the OPPONENT can win where
    they stand — `_swap_off` run on each of her own occupied squares with
    the opponent capturing first. [(square, piece, loss), ...], biggest
    loss first; the king is left out, check being the rules' business and
    not an exchange. This exists because `material_loss` reads only the
    candidate move's destination square: thirteen of the twenty-seven
    decisive drops in the four thrown games were pieces standing loose
    somewhere ELSE while she moved elsewhere, each such move printed to
    her as safe (engineering record
    i-throw-won-games-at-the-end-and-nobody-has-look, 2026-08-22)."""
    if side is None:
        side = board.turn
    out = []
    for sq in chess.SquareSet(board.occupied_co[side]):
        if board.piece_type_at(sq) == chess.KING:
            continue
        loss = _swap_off(board, sq, not side)
        if loss > 0:
            out.append((sq, board.piece_at(sq), loss))
    out.sort(key=lambda t: -t[2])
    return out


def _new_capture_tag(board, move, reply):
    """' — a capture your move first allows' when `reply`'s capturing attack
    did not exist before `move` — an opened line or a vacated square, the
    browser-030 self-block (Bg6 walking the f5 bishop off the fifth rank and
    handing Qh5 the c5 queen) being the measured case. `board` arrives with
    `move` already pushed and is handed back the same way."""
    board.pop()
    try:
        existed = (board.piece_at(reply.to_square) is not None
                   and reply.to_square != move.from_square
                   and reply.from_square in board.attackers(
                       not board.turn, reply.to_square))
    finally:
        board.push(move)
    return "" if existed else " — a capture your move first allows"


def worst_reply(board, move):
    """The sharpest one-ply answer to `move` the machine can see:
    (loss, reply_san, why), or (0, None, None) when every reply is quiet.
    This is the per-candidate question the destination-square test and the
    standing sweep both leave unasked — what does the opponent's NEXT move
    do about the board this candidate leaves behind (spec: chess-mover-
    amendment.md, "The reply scan"). Three detectors, dearest answer wins:

    - captures, priced by the same `_swap_off` as the standing sweep, run
      over every mover piece in the post-move position — a defence
      abandoned, a line opened, and a square vacated all land here;
    - a reply that is checkmate, at MATE_LOSS above every material number;
    - forks by a knight, queen, or pawn that land where the mover cannot
      profitably remove them and hit two targets worth a minor or more —
      or the king and one such target — each target priced by the exchange
      on its square, never face value: a "fork" of a defended piece whose
      capture loses the forker is not a fork.
    """
    mover_side = board.turn
    best = (0, None, None)
    board.push(move)
    try:
        opp = board.turn
        # -- captures: the standing sweep on the board the candidate leaves
        for sq, piece, loss in standing_losses(board, mover_side):
            if loss <= best[0]:
                continue
            attackers = board.attackers(opp, sq)
            if not attackers:
                continue
            reply = chess.Move(
                min(attackers,
                    key=lambda s: PIECE_VALUE[board.piece_type_at(s)]), sq)
            if reply not in board.legal_moves:
                # the cheapest attacker is pinned; any legal capture will do
                legal = [r for r in board.legal_moves
                         if r.to_square == sq and board.is_capture(r)]
                if not legal:
                    continue
                reply = min(legal, key=lambda r: PIECE_VALUE[
                    board.piece_type_at(r.from_square)])
            best = (loss, board.san(reply),
                    "takes the %s on %s%s" % (
                        PIECE_NAME[piece.piece_type], chess.square_name(sq),
                        _new_capture_tag(board, move, reply)))
        # -- mate, and forks: one push per opponent reply
        for reply in board.legal_moves:
            pt = board.piece_type_at(reply.from_square)
            victim = board.piece_type_at(reply.to_square)
            board.push(reply)
            try:
                if board.is_check() and board.is_checkmate():
                    board.pop()
                    san = board.san(reply)
                    board.push(reply)
                    best = (MATE_LOSS, san, "checkmate")
                    break
                if pt not in (chess.KNIGHT, chess.QUEEN, chess.PAWN):
                    continue
                forker = reply.to_square
                targets = [s for s in (board.attacks(forker)
                                       & chess.SquareSet(
                                           board.occupied_co[mover_side]))
                           if board.piece_type_at(s) != chess.KING
                           and PIECE_VALUE[board.piece_type_at(s)] >= 300]
                check = board.is_check()
                if not targets and not check:
                    continue
                gains = sorted(((_swap_off(board, s, opp), s)
                                for s in targets), reverse=True)
                gains = [(g, s) for g, s in gains if g > 0]
                if check and gains:
                    est = gains[0][0]
                    what = "your king and your " + PIECE_NAME[
                        board.piece_type_at(gains[0][1])]
                elif len(gains) >= 2:
                    # two targets, one move to save them: the lesser falls
                    est = gains[1][0]
                    what = "your %s and your %s" % (
                        PIECE_NAME[board.piece_type_at(gains[0][1])],
                        PIECE_NAME[board.piece_type_at(gains[1][1])])
                else:
                    continue
                if _swap_off(board, forker, mover_side) > 0:
                    continue  # the forker itself falls at a profit
                total = est + (PIECE_VALUE[victim] if victim else 0)
                if total <= best[0]:
                    continue
                board.pop()
                san = board.san(reply)
                head = ""
                if victim:
                    head = "takes the %s on %s%s, then " % (
                        PIECE_NAME[victim], chess.square_name(reply.to_square),
                        _new_capture_tag(board, move, reply))
                board.push(reply)
                best = (total, san, head + "forks " + what)
            finally:
                board.pop()
    finally:
        board.pop()
    return best


def material_balance(board, side=None):
    """Centipawns `side` (default: the side to move) is ahead, kings out."""
    if side is None:
        side = board.turn
    return sum(PIECE_VALUE[pt] * (len(board.pieces(pt, side))
                                  - len(board.pieces(pt, not side)))
               for pt in (chess.PAWN, chess.KNIGHT, chess.BISHOP,
                          chess.ROOK, chess.QUEEN))


def trade_guard_line(board):
    """The named-trades line (chess-mover-amendment.md, "Trades while ahead
    are counted, not reflexed"), or None when it is not owed. Ahead by three
    pawns or more with a piece — never a pawn — takeable, every such trade
    is named with the balance it leaves, so simplification is a counted
    decision rather than the reflex that threw the recorded endgames."""
    bal = material_balance(board)
    if bal < 300:
        return None
    entries = []
    for m in board.legal_moves:
        victim = board.piece_type_at(m.to_square)
        if victim in (None, chess.PAWN):
            continue
        after = bal + PIECE_VALUE[victim] - material_loss(board, m)
        entries.append("%s (%s) takes their %s and leaves you %+.1f" % (
            board.san(m), m.uci(), PIECE_NAME[victim], after / 100))
    if not entries:
        return None
    return ("You are ahead %.1f pawns. A piece trade while ahead banks the "
            "win only when the count after it still reads for you — count "
            "each, never reflex: " % (bal / 100) + "; ".join(entries))


def passed_pawns(board):
    """Every passed pawn on the board: [(colour, square, steps-to-promote,
    notes)], notes being (path square, enemy piece type, blocks?) for each
    path square an enemy piece sits on (blocks) or attacks (guards)."""
    out = []
    for colour in (chess.WHITE, chess.BLACK):
        step = 1 if colour == chess.WHITE else -1
        enemy_pawn = chess.Piece(chess.PAWN, not colour)
        for sq in board.pieces(chess.PAWN, colour):
            f, r = chess.square_file(sq), chess.square_rank(sq)
            ranks = range(r + step, 8 if colour == chess.WHITE else -1, step)
            if any(board.piece_at(chess.square(ff, rr)) == enemy_pawn
                   for rr in ranks for ff in (f - 1, f, f + 1)
                   if 0 <= ff <= 7):
                continue
            notes = []
            path = [chess.square(f, rr) for rr in ranks]
            for p in path:
                occ = board.piece_at(p)
                if occ is not None and occ.color != colour:
                    notes.append((p, occ.piece_type, True))
                    continue
                guards = board.attackers(not colour, p)
                if guards:
                    guard = min(guards, key=lambda s: PIECE_VALUE[
                        board.piece_type_at(s)])
                    notes.append((p, board.piece_type_at(guard), False))
            out.append((colour, sq, len(path), notes))
    return out


def passed_pawn_line(board, side=None):
    """One line, both sides, always rendered — "none" included, an absent
    line being indistinguishable from the scan having failed (chess-mover-
    amendment.md, "Passed pawns are named"). Each passed pawn carries its
    square, its steps from promoting, and what stands in the way — a clear
    path said to be clear, because "nothing stops it" is the fact that
    demands a move: browser-032's f-pawn walked five clear squares to f8
    with the prompt saying nothing."""
    if side is None:
        side = board.turn
    rendered = {True: [], False: []}
    for colour, sq, steps, notes in passed_pawns(board):
        mine = colour == side
        defender = "their" if mine else "your"
        if notes:
            det = ", ".join(
                "%s %s %s %s" % (defender, PIECE_NAME[pt],
                                 "blocks" if occupied else "guards",
                                 chess.square_name(p))
                for p, pt, occupied in notes[:3])
        else:
            det = ("path clear — nothing of %s blocks or guards it"
                   % ("theirs" if mine else "yours"))
        rendered[mine].append("%s, %d from promoting (%s)" % (
            chess.square_name(sq), steps, det))
    return ("Passed pawns — yours: %s; theirs: %s" % (
        "; ".join(rendered[True]) or "none",
        "; ".join(rendered[False]) or "none"))


# --- position memory in the prompt (specs/chess-reflex.md rule 14) ----------
# The retrieval lives HERE, in the mover's own prompt build, never in a job
# builder: the note design (reason_note handed in on the job) left every
# middlegame stamp `empty` — its 0.75 floor silenced memory at the very plies
# browser-022/023/024 collapsed at — and a caller that forgets to pass a note
# costs her the context without anyone noticing. Retrieval is brute force and
# cheap (19-40 ms over the 3,238-row live store, measured 2026-08-21), so it
# runs at every ply with no opening gate and no similarity floor: distance is
# priced by printing the similarity on the line, not by silence.

def _prompt_sim_k():
    try:
        return int(os.environ.get("DESKCRAB_CHESS_PROMPT_SIM_K", "3"))
    except ValueError:
        return 3


def _record_words(wins, draws, losses):
    return ", ".join(f"{word} {n}" for word, n in
                     (("won", wins), ("drew", draws), ("lost", losses)) if n)


def memory_sections(board):
    """(lines, endorsed, stamp): the position memory rendered for the move
    prompt. `lines` go above the legal-move lists; `endorsed` is the set of
    UCI moves whose remembered record is net-winning (rule 14c: the exchange
    count may not bury one); `stamp` is the `similar-context` metric detail,
    or None when no stamp is owed. There is NO exact-position block here
    (rule 14a): an exact hit is the reflex's business, answered before any
    prompt is built, so the memory a prompt carries is the similar section
    only — nearest non-exact neighbours, each with a finished result behind
    it. Never raises: any failure is a bare prompt, never a lost move."""
    if os.environ.get("DESKCRAB_CHESS_MEMORY_PROMPT", "1") == "0":
        return [], set(), None
    lines, endorsed = [], set()
    fen = board.fen()
    # -- the similar section (rule 14b) ------------------------------------
    if os.environ.get("DESKCRAB_CHESS_SIMILAR", "1") == "0":
        return lines, endorsed, None
    try:
        import chess_reflex
        import chess_similar
        k = _prompt_sim_k()
        hits = chess_similar.similar(fen, k + 4)
        stamp_top = (f"top {hits[0]['san']} {hits[0]['similarity']:.2f}"
                     if hits else "top none")
        picked = [h for h in hits if not h["exact"]][:k]
        # The k nearest are selected by the retrieval's own ranking, then
        # ordered for rendering by OUTCOME-weighted similarity: a winning
        # precedent outranks a nearer loss, because nearness alone is never
        # advice.
        picked.sort(key=lambda h: (
            -h["similarity"] * chess_reflex.score(h["wins"], h["draws"],
                                                  h["n"]),
            -h["similarity"]))
        sim_lines = []
        for h in picked:
            if h["n"] == 1:
                word = ("won" if h["wins"] else
                        "drew" if h["draws"] else "lost")
                ended = f"{h['colour']} {word} that game"
            else:
                ended = (f"{h['colour']} "
                         + _record_words(h["wins"], h["draws"], h["losses"])
                         + f" of those {h['n']} games")
            if h["losses"] > h["wins"]:
                ended += " — a warning, not a suggestion"
            elif h["wins"] > h["losses"]:
                try:
                    mv = chess.Move.from_uci(h["move"])
                    if mv in board.legal_moves:
                        endorsed.add(h["move"])
                except (chess.InvalidMoveError, ValueError):
                    pass
            sim_lines.append(f"- similarity {h['similarity']:.2f}: "
                             f"{h['san']} as {h['colour']} ({h['game_id']} "
                             f"ply {h['ply']}) — {ended}")
        if sim_lines:
            lines.append("Positions like this one from her finished games — "
                         "similar is not same; weigh each against this "
                         "board, and weigh how the game ended harder than "
                         "how near it looks:")
            lines.extend(sim_lines)
        stamp = ("attached " if sim_lines else "empty ") + stamp_top
    except Exception:
        stamp = "error"
    return lines, endorsed, stamp

# How long a posted (or stale-discarded) position stays claimed. Only an undo
# can bring the same position back inside this window, and the poll's resync
# path resets the mover outright on one, so this is a dedup horizon rather
# than a wait anyone experiences.
POSTED_TTL = 10.0


# --- Self-play: its own model, and a hard nightly budget --------------------
# specs/chess-selfplay.md rules 2-5. On 2026-08-15 an overnight self-play
# driver inherited DESKCRAB_CHESS_MOVER_MODEL — the user's knob for REAL
# games — and made ~1,590 calls on the dearest model in the house, draining
# its per-account allowance on every login; the refusals cooled whole
# accounts and by morning a real question died on "every login is over its
# limit". Both guards live HERE, keyed off the job, so no driver — the
# repo's, or a copy written into a data directory by some future hand — can
# opt back out of either.

def is_selfplay(job):
    """specs/chess-selfplay.md rule 1: the id prefix and the opponent name
    are the whole test, so a game against a person can never trip it."""
    return (str(job.get("gid", "")).startswith("selfplay-")
            or job.get("opponent") == "selfplay")


def _chess_dir():
    return Path(os.environ.get("DESKCRAB_CHESS_DIR",
                               str(Path.home() / ".local/share/deskcrab/chess")))


def night_key(now=None):
    """The budget window's key (specs/chess-selfplay.md rule 4): the calendar
    date of (now - 12 h), so the night of day D runs noon D to noon D+1 and a
    session crossing midnight stays on the same night's records — a chain
    started before midnight cannot draw a second budget at 00:00."""
    if now is None:
        now = time.time()
    return time.strftime("%Y%m%d", time.localtime(now - 12 * 3600))


def _selfplay_calls_file():
    return (_chess_dir() / "selfplay"
            / ("model-calls-" + night_key() + ".log"))


def selfplay_nightly_moves():
    try:
        return int(os.environ.get("DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES",
                                  "150"))
    except ValueError:
        return 150


def selfplay_live_session():
    """Whether an attended run may continue past the nightly call ceiling.

    Calls remain serialized and recorded in the normal audit log; only the
    unattended spending refusal is disabled.
    """
    return os.environ.get("DESKCRAB_CHESS_SELFPLAY_LIVE_SESSION", "").lower() \
        in {"1", "true", "yes", "on"}


def selfplay_models():
    """The models a self-play job may name for itself (specs/chess-selfplay.md
    rule 15): the benchmark's allowlist, cheap Claude names by default. The
    operator widens it deliberately, per run, never here."""
    return (os.environ.get("DESKCRAB_CHESS_SELFPLAY_MODELS")
            or "haiku sonnet").split()


def selfplay_job_model(job, alert=lambda *a: None):
    """The model a SELF-PLAY job's own `model` field earns it: the field
    itself when it is allowlisted, else None (rule 2's knob decides). A
    codex-family name is refused like any other unlisted name, and its
    listing must be EXPLICIT (specs/chess-selfplay.md rule 15, amended
    2026-08-29 for the family-crossing matrix): the one codex login is the
    user's conversation engine, and putting it into a grind is a deliberate
    per-run operator act, never a default. An unlisted name is refused
    loudly rather than silently honoured: 2026-08-15 is what a self-play
    loop quietly naming a dear model does."""
    model = (job.get("model") or "").strip()
    if not model:
        return None
    if model not in selfplay_models():
        if _codex_backend(model):
            alert("mover: self-play job %s names codex-family model %r "
                  "outside DESKCRAB_CHESS_SELFPLAY_MODELS (%s) — refused, "
                  "the conversation engine grinds only when listed "
                  "explicitly; using the self-play default"
                  % (job.get("gid"), model, " ".join(selfplay_models())))
        else:
            alert("mover: self-play job %s names model %r outside "
                  "DESKCRAB_CHESS_SELFPLAY_MODELS (%s) — refused, using "
                  "the self-play default" % (job.get("gid"), model,
                                             " ".join(selfplay_models())))
        return None
    return model


def selfplay_calls_tonight():
    """Lines in the night's counter file — one per model attempt, appended
    with O_APPEND so concurrent movers count truly."""
    try:
        with open(_selfplay_calls_file(), encoding="utf-8",
                  errors="replace") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def selfplay_budget_spent():
    return (not selfplay_live_session()
            and selfplay_calls_tonight() >= selfplay_nightly_moves())


def _selfplay_charge(detail):
    """Atomically record one self-play attempt and reserve its budget slot.

    An unattended run returns False when another worker has already claimed
    the final nightly slot. An attended live session always appends the call
    and returns True. An unreadable counter remains best-effort and returns
    True: failure to record a metric must not turn into a lost chess move.
    """
    try:
        path = _selfplay_calls_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a+", encoding="utf-8") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.seek(0)
            if (not selfplay_live_session()
                    and sum(1 for _ in fh) >= selfplay_nightly_moves()):
                return False
            fh.seek(0, os.SEEK_END)
            fh.write("%s\t%s\n" % (time.strftime("%F %T"), detail))
            fh.flush()
        return True
    except OSError:
        return True


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


# --- The clock is the only ceiling (specs/chessweb.md rule 16g) -------------
# Rewritten 2026-08-31 by the user's ruling: the fixed per-call ceiling and
# the manufactured fallback move are both unauthorized, in real games and in
# benchmarks alike. A TIMED attempt is bounded by the moving side's actual
# remaining clock and by nothing else; an attempt still unanswered when the
# flag falls is killed and the fallen flag IS the result. An UNTIMED attempt
# has no ceiling at all: a failed or dead process is exposed and retried
# (rule 16e), never answered for.


def _job_remaining(job, now=None):
    """Seconds left on the moving side's clock RIGHT NOW, from the job's
    clock snapshot aged by the wall time since detection — or None for an
    untimed game, a job carrying no clock, or an unreadable one."""
    ck = job.get("clock")
    if not isinstance(ck, dict):
        return None
    ms = ck.get((job.get("side") or "") + "_ms")
    if not isinstance(ms, (int, float)):
        return None
    now = time.time() if now is None else now
    try:
        aged = max(0.0, now - float(job.get("t0") or now))
    except (TypeError, ValueError):
        aged = 0.0
    return ms / 1000.0 - aged


# Output lines carrying one of these name the failure better than whatever
# the CLI happened to print last: on 2026-08-11 a settings-file warning on
# stderr masked "You've hit your session limit" on stdout in every logged
# failure, and the loop was diagnosed from the wrong line for half an hour.
_CAUSE_MARKERS = ("session limit", "usage limit", "rate limit", "not logged",
                  "please run /login", "overloaded", "credit balance",
                  "api error", "billing")

_SUBSCRIPTION_LIMIT_MARKERS = (
    "usage limit", "session limit", "weekly limit", "5-hour limit",
    "5h limit", "out of usage credits", "credit balance",
    "insufficient credit", "credits depleted", "credits exhausted",
    "spend control", "plan limit", "quota exhausted",
)
_SERVER_CAPACITY_MARKERS = (
    "serveroverloaded", "server overloaded", "at capacity",
    "model is currently overloaded", "model overloaded", "http 529",
)
_ACCOUNT_AUTH_MARKERS = (
    "not logged in", "login required", "please run /login",
    "failed to authenticate", "oauth session expired", "token expired",
    "401 unauthorized",
)


def server_capacity_failure(text):
    """Whether a failure names transient provider/server capacity."""
    low = (text or "").lower()
    return any(marker in low for marker in _SERVER_CAPACITY_MARKERS)


def subscription_limit_failure(text):
    """Whether a failure names exhausted account/subscription allowance.

    Capacity is explicitly excluded even if a provider wraps it in generic
    retry wording: capacity is resumable infrastructure state, not allowance.
    """
    low = (text or "").lower()
    return (not server_capacity_failure(low)
            and any(marker in low
                    for marker in _SUBSCRIPTION_LIMIT_MARKERS))


def account_auth_failure(text):
    """Whether the configured account cannot authenticate."""
    low = (text or "").lower()
    return any(marker in low for marker in _ACCOUNT_AUTH_MARKERS)


# --- The codex engine (specs/model-backends.md rule 15) ---------------------
# The engine follows the model name, here as everywhere: a codex-family
# mover model tries the one codex login first and falls through to the
# Claude accounts, because a game in flight must not stall on a dry engine.
# These four mirror lib/common.sh's router — one spelling each side, held
# together by tests/test_model_backends.sh.

def _codex_backend(model):
    m = (model or "").lower()
    return (m.startswith("codex:") or m.startswith("gpt-")
            or bool(re.match(r"gpt\d", m)) or bool(re.match(r"o\d", m))
            or m == "sol" or m.startswith("sol-") or m.endswith("-sol"))


def _codex_resolve(model):
    m = model[len("codex:"):] if model.startswith("codex:") else model
    if m == "sol":
        m = os.environ.get("CODEX_MODEL_SOL") or "gpt-5.6-sol"
    return m


def _selfplay_model_forbidden(model):
    """Models reserved for live play and permanently barred from grinds."""
    return _codex_resolve(model or "") in {
        "spark", "gpt-5.3-codex-spark",
    }


def _codex_cooling():
    f = os.environ.get("DESKCRAB_CODEX_STATE") or os.path.join(
        os.environ.get("XDG_DATA_HOME")
        or os.path.expanduser("~/.local/share"), "deskcrab", "codex-state")
    try:
        with open(f) as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if (p and p[0] == "blocked-until" and len(p) > 1
                        and p[1].isdigit() and int(p[1]) > time.time()):
                    return True
    except OSError:
        pass
    return False


def _codex_jsonl_answer(out):
    """(text, usage) when the stdout is a codex `--json` event stream —
    text may be "" for a run that answered nothing — else (None, None).
    Decoding before the move parse is as load-bearing as it is for the
    Claude result object: raw JSON is full of hex ids whose substrings
    read as legal UCI squares."""
    saw, text, usage = False, "", None
    for line in (out or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if not isinstance(d, dict):
            continue
        t = d.get("type") or ""
        if t in ("thread.started", "turn.started", "turn.completed",
                 "turn.failed", "item.completed"):
            saw = True
        if t == "item.completed":
            item = d.get("item") or {}
            if item.get("type") == "agent_message":
                text = item.get("text") or text
        elif t == "turn.completed":
            u = d.get("usage") or {}

            def n(k):
                try:
                    return int(u.get(k) or 0)
                except (TypeError, ValueError):
                    return 0
            cached = n("cached_input_tokens")
            usage = {"input_tokens": max(n("input_tokens") - cached, 0),
                     "cache_read_input_tokens": cached,
                     "cache_creation_input_tokens":
                         n("cache_write_input_tokens"),
                     "output_tokens": n("output_tokens")}
    return (text, usage) if saw else (None, None)


def _move_schema(legal_uci):
    """A closed structured-output schema for this exact position."""
    legal = list(dict.fromkeys(legal_uci or ()))
    if not legal:
        raise ValueError("a move schema requires at least one legal move")
    return {
        "type": "object",
        "properties": {
            "move": {"type": "string", "enum": legal},
        },
        "required": ["move"],
        "additionalProperties": False,
    }


def _structured_move(doc):
    """The move field emitted by a structured Claude result, if present."""
    if not isinstance(doc, dict):
        return None
    for key in ("structured_output", "structuredOutput"):
        value = doc.get(key)
        if isinstance(value, dict) and isinstance(value.get("move"), str):
            return value["move"]
    return None


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
        self.rejected = {}        # key -> short invalid reply for retry wording
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
            self.rejected.pop(key, None)
        if len(self.resolved) > 64:
            for k in sorted(self.resolved,
                            key=lambda k: self.resolved[k][1])[:32]:
                del self.resolved[k]
                self.fails.pop(k, None)
                self.fail_why.pop(k, None)
                self.rejected.pop(k, None)
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
            self.rejected.clear()
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
        selfplay = is_selfplay(job)
        if selfplay and _selfplay_model_forbidden(job.get("model")):
            why = ("model %r is permanently excluded from self-play and "
                   "benchmark calls" % job.get("model"))
            self.alert(f"mover: {job['gid']} ply {job['ply']} refused — {why}")
            return "failed", why
        effort = job.get("effort") or os.environ.get(
            "DESKCRAB_CHESS_MOVER_EFFORT", "low")
        if selfplay and effort in {"max", "ultra"}:
            why = ("effort %r is above chess's permanent xhigh ceiling"
                   % effort)
            self.alert(f"mover: {job['gid']} ply {job['ply']} refused — {why}")
            return "failed", why
        # The nightly budget binds BEFORE anything boots: a self-play
        # position past the cap is refused without a CLI call, whoever is
        # driving (specs/chess-selfplay.md rule 5).
        if selfplay and selfplay_budget_spent():
            why = ("selfplay nightly move budget spent (%d/%d)"
                   % (selfplay_calls_tonight(), selfplay_nightly_moves()))
            self.alert(f"mover: {job['gid']} ply {job['ply']} refused — {why}")
            return "failed", why
        # The job's own model, when it may carry one: a self-play job's is
        # allowlist-bound (specs/chess-selfplay.md rule 15); a real game's is
        # the bridge's per-speed offer (chessweb.md rule 16b), passed as-is.
        if selfplay:
            job_model = selfplay_job_model(job, alert=self.alert)
        else:
            job_model = (job.get("model") or "").strip() or None
        if (selfplay and job_model and _codex_backend(job_model)
                and _codex_cooling()):
            why = "subscription limit: configured codex login is cooling"
            self.alert(f"mover: {job['gid']} ply {job['ply']} refused — {why}")
            return "failed", why
        prior_rejection = self.rejected.get(job["key"])
        prompt = self._prompt(job, board, prior_rejection)
        move = None
        last_why = ""
        # The clock is the only ceiling (rule 16g, rewritten 2026-08-31): a
        # timed job's attempt runs until it answers or the moving side's
        # flag falls, remaining re-read before every attempt so a retry
        # walk cannot spend what the first attempt already burned. An
        # untimed job's attempt has no ceiling at all.
        clocked = _job_remaining(job) is not None
        legal_uci = [move.uci() for move in board.legal_moves]
        # Structured output measurably adds latency at Low. Keep the normal
        # legal-list path fast; once a backend ignores that list, every later
        # attempt for the position gets the closed enum schema. The mutable
        # state is read lazily by _attempts, so account 2 is constrained when
        # account 1 has just returned an illegal token.
        schema_state = {
            "legal_uci": legal_uci if prior_rejection else None,
        }
        for label, cmd, env in self._attempts(
                effort, selfplay, job_model, schema_state=schema_state):
            timeout = None
            if clocked:
                remaining = _job_remaining(job)
                if remaining is None or remaining <= 0:
                    last_why = last_why or "flag fell before an attempt"
                    break
                timeout = remaining
            t0 = time.time()
            if (selfplay and not _selfplay_charge(
                    f"{job['gid']} ply {job['ply']} {label}")):
                last_why = ("selfplay nightly move budget spent (%d/%d)"
                            % (selfplay_calls_tonight(),
                               selfplay_nightly_moves()))
                break
            self.metric("model-start",
                        f"{job['gid']} ply {job['ply']} effort {effort} "
                        f"{label}")
            out, why = self._call(cmd, env, prompt, timeout=timeout)
            dt = time.time() - t0
            if why == "superseded":
                self.metric("model-end",
                            f"{job['gid']} ply {job['ply']} {dt:.1f}s "
                            f"superseded")
                self.log(f"mover: {job['gid']} ply {job['ply']} superseded "
                         f"after {dt:.1f}s — answering the newer position")
                return None, None
            move = self._parse(board, out) if out else None
            rejected = self._reply_label(out) if out and not why else ""
            outcome = "ok" if move else (why or (
                "no-legal-move" + (f" ({rejected})" if rejected else "")))
            self.metric("model-end",
                        f"{job['gid']} ply {job['ply']} {dt:.1f}s {outcome}")
            if move:
                break
            if rejected:
                self.rejected[job["key"]] = rejected
                schema_state["legal_uci"] = legal_uci
                prompt = self._prompt(job, board, rejected)
            last_why = f"{label}: {outcome}"
            self.alert(f"mover: {job['gid']} ply {job['ply']} attempt "
                       f"{label} came back {outcome} after {dt:.1f}s")
        if move is None and clocked and (_job_remaining(job) or 0) <= 0:
            # The flag fell with no answer (rule 16g): the game is over as
            # a genuine clock loss, computed by rule 22b wherever state is
            # next read. Nothing is played and nothing is manufactured.
            self.metric("mover-flag",
                        f"{job['gid']} ply {job['ply']} flag fell with no "
                        f"answer ({last_why or 'no attempt ran'})")
            self.alert(f"mover: {job['gid']} ply {job['ply']} flag fell "
                       f"with no answer ({last_why or 'no attempt ran'}) — "
                       f"the clock loss stands, no move played")
            return "failed", last_why or "flag fell with no answer"
        if move is None:
            self.alert(f"mover: {job['gid']} ply {job['ply']}: every attempt "
                       f"failed — last: {last_why or 'no attempts ran'}")
            return "failed", last_why
        return ("posted" if self.play(job, move) else "stale"), None

    # -- the call ----------------------------------------------------------
    def _attempts(self, effort, selfplay=False, job_model=None,
                  legal_uci=None, schema_state=None):
        def schema_moves():
            if schema_state is not None:
                return schema_state.get("legal_uci")
            return legal_uci

        override = os.environ.get("DESKCRAB_CHESS_MOVER_CMD")
        if override:
            yield "stub", shlex.split(override), self._env(None)
            return
        model = job_model or self._model(selfplay)
        if _codex_backend(model):
            if selfplay:
                # An honoured codex SELF-PLAY job plays through the codex
                # login ALONE (specs/chess-selfplay.md rule 15): a benchmark
                # cell that silently substituted engines would measure
                # nothing, and the fallback walk would let a grind spend
                # Claude allowance under a codex flag. A cooling login
                # yields no attempt at all — the benchmark driver cancels
                # the worker without turning the account refusal into clock
                # evidence.
                if _codex_cooling():
                    self.alert("mover: codex login is cooling — no attempt "
                               "for self-play model %r" % model)
                    return
                env = self._env(None)
                env.pop("OPENAI_API_KEY", None)
                yield ("codex",
                       self._codex_cmd(effort, selfplay, model=model,
                                       legal_uci=schema_moves()), env)
                return
            # A ROUTED offer — a real-game job carrying the bridge's
            # per-speed model (chessweb.md rule 16b) — preserves EXACT
            # model identity (model-backends.md rule 15): the routed codex
            # model or nothing, never a Claude substitute. Refused or
            # cooling yields no further attempt; the move stays unplayed
            # and rule 16e's alert/stall machinery makes the failure
            # visible while the position is re-offered on its cooldown.
            if job_model:
                if _codex_cooling():
                    self.alert("mover: codex login is cooling — no attempt "
                               "for routed model %r; identity preserved, "
                               "no substitute engine" % model)
                    return
                env = self._env(None)
                env.pop("OPENAI_API_KEY", None)
                yield ("codex",
                       self._codex_cmd(effort, selfplay, model=model,
                                       legal_uci=schema_moves()), env)
                return
            # specs/model-backends.md rule 15: an ENV-CHAIN codex model
            # tries the one codex login first — unless it is already
            # cooling — then the Claude accounts at the fallback model, so
            # a game in flight never stalls on a dry engine. `ultra` is
            # codex's own top effort; the Claude CLI refuses the word, so
            # the fallback attempts clamp it.
            if not _codex_cooling():
                env = self._env(None)
                env.pop("OPENAI_API_KEY", None)
                yield ("codex",
                       self._codex_cmd(effort, selfplay, model=model,
                                       legal_uci=schema_moves()), env)
            model = os.environ.get("CODEX_FALLBACK_MODEL") or "sonnet"
            if _codex_backend(model):
                model = "sonnet"
            if effort == "ultra":
                effort = "max"
        for number, conf in self._accounts(model):
            yield (f"account {number}",
                   self._claude_cmd(effort, selfplay, model=model,
                                    legal_uci=schema_moves()),
                   self._env(conf))

    @staticmethod
    def _model(selfplay=False):
        """The call's own model — the walk filters cooldowns by it
        (specs/account-fallback.md rule 10), and _claude_cmd puts it on the
        argv. One reader, two users, so they cannot drift. Self-play has its
        own knob and NEVER reads the real-game one (specs/chess-selfplay.md
        rule 2) — inheriting it is how a night of self-play drained the
        user's own model allowance (2026-08-15)."""
        if selfplay:
            return os.environ.get("DESKCRAB_CHESS_SELFPLAY_MODEL") or "sonnet"
        return (os.environ.get("DESKCRAB_CHESS_MOVER_MODEL")
                or os.environ.get("CLAUDE_MODEL") or "sonnet")

    @staticmethod
    def _accounts(model=""):
        """(number, config dir) pairs, in the order worth trying for `model`.

        The flat numbered list of specs/account-fallback.md — account 1 is
        ~/.claude, then the CLAUDE_FALLBACK_CONFIG_DIR entries — rotated to
        the current account and with accounts cooling FOR THIS MODEL skipped:
        a cooldown scoped `all` covers every model, one scoped to a family
        covers only its own, and a record without the scope field reads as
        `all` (rules 8a, 8b) — so another family's drought never benches a
        mover call, which is the drought this machinery was rebuilt for (the
        2026-08-15 selfplay burn drained the premium pools and the
        model-blind cooldowns benched every account's healthy capacity).
        Read from the same state file every other walker shares; with
        everything cooling for the model, the soonest to expire alone (never
        empty). Read-only: recording a refusal is the session machinery's
        call, never a chess move's.

        systemd's EnvironmentFile hands values through unexpanded (the same
        trap _claude_cmd guards CLAUDE_BIN against): a literal "$HOME/..."
        handed to CLAUDE_CONFIG_DIR names an empty login that answers "Not
        logged in" while the real account sits logged in (2026-08-11). Every
        dir — the list's entries AND the state file's — is expanded before it
        is matched or handed out, so an unexpanded entry never wedges the walk
        onto a dead login."""
        def expand(d):
            return os.path.expanduser(os.path.expandvars(d))
        # The family roster's one spelling is common.sh's, handed through the
        # environment as DESKCRAB_MODEL_FAMILIES (specs/account-fallback.md
        # rule 29); the baked list is a last resort for a mover started
        # outside the shell paths — which this service usually is.
        fams = [f for f in re.split(
            r"[\s:]+",
            os.environ.get("DESKCRAB_MODEL_FAMILIES", "").strip()
            or "fable opus sonnet haiku") if f]
        fam_m = re.search("|".join(re.escape(f) for f in fams),
                          model or "", re.I)
        fam = fam_m.group(0).lower() if fam_m else ""
        dirs = [expand("~/.claude")]
        for d in re.split(r"[:\s]+",
                          os.environ.get("CLAUDE_FALLBACK_CONFIG_DIR", "")):
            if d:
                e = expand(d)
                if e not in dirs:
                    dirs.append(e)
        state_file = os.environ.get("ACCOUNT_STATE_FILE") or os.path.join(
            os.environ.get("XDG_DATA_HOME",
                           os.path.expanduser("~/.local/share")),
            "deskcrab", "account-state")
        current, cooling = 1, {}
        now = time.time()
        try:
            with open(state_file) as fh:
                for line in fh:
                    f = line.rstrip("\n").split("\t")
                    if len(f) < 4:
                        continue
                    d = expand(f[2])
                    if d not in dirs:
                        continue
                    n = dirs.index(d) + 1
                    if f[0] == "current":
                        current = n
                    elif f[0] == "cooldown":
                        try:
                            until = int(f[3])
                        except ValueError:
                            continue
                        scope = f[5] if len(f) >= 6 and f[5] else "all"
                        if fam and scope not in ("all", fam):
                            continue
                        # The latest covering record decides (rule 8b): an
                        # account cooling under two scopes at once is
                        # selectable only when both have lapsed.
                        if until > now and until > cooling.get(n, 0):
                            cooling[n] = until
        except OSError:
            pass
        if not 1 <= current <= len(dirs):
            current = 1
        order = [(i - 1) % len(dirs) + 1
                 for i in range(current, current + len(dirs))]
        free = [n for n in order if n not in cooling]
        if not free:
            free = [min(cooling, key=cooling.get)]
        return [(n, dirs[n - 1]) for n in free]

    @classmethod
    def _claude_cmd(cls, effort, selfplay=False, model=None,
                    legal_uci=None):
        # A conf-set CLAUDE_BIN can arrive with $HOME still in it: systemd's
        # EnvironmentFile hands values through unexpanded, where every shell
        # path expanded them on the way in.
        claude = os.environ.get("CLAUDE_BIN", "")
        if claude:
            claude = os.path.expanduser(os.path.expandvars(claude))
        if not claude or not os.path.exists(claude):
            claude = (shutil.which("claude")
                      or os.path.expanduser("~/.local/bin/claude"))
        model = model or cls._model(selfplay)
        # --output-format json: the run's own result object carries the exact
        # usage the token ledger keeps (specs/metrics.md rule 15). The answer
        # is read from its `result` field in _call; a stdout that is not that
        # object (a stub, an older CLI) stays the whole answer as before.
        cmd = [claude, "-p", "--dangerously-skip-permissions",
               "--model", model, "--effort", effort,
               "--output-format", "json",
               "--disable-slash-commands",
               "--system-prompt", SYSTEM_PROMPT]
        if legal_uci:
            schema = json.dumps(_move_schema(legal_uci),
                                separators=(",", ":"))
            cmd += ["--json-schema", schema]
        empty_mcp = Path(__file__).resolve().parent / "empty-mcp.json"
        if not empty_mcp.is_file():
            # Fail CLOSED (specs/chessweb.md rule 24f): --tools "" is what
            # disarms this call, and it is only safe behind the empty MCP
            # config — without it the CLI inlines every MCP schema instead
            # of deferring them (the 116k-token trap,
            # tools/context-probe-results.md). The mover's prompt carries
            # the sitter's typed name; it must never run tool-armed. A
            # lost move beats an armed one.
            raise RuntimeError(
                "empty-mcp.json is missing beside chess_mover.py — "
                "refusing to run the move call with tools armed")
        cmd += ["--strict-mcp-config", "--mcp-config", str(empty_mcp),
                "--tools", ""]
        return cmd

    @classmethod
    def _codex_cmd(cls, effort, selfplay=False, model=None,
                   legal_uci=None):
        """The codex spelling of the same call (specs/model-backends.md
        rules 5-7, 15): the one login's auth from CODEX_HOME, the user's own
        config held out, the mover's system prompt as the session's base
        instructions, the question on stdin. `model` is the job's own model
        when it carries one — a benchmark side's configuration, the bridge's
        per-speed offer — else the environment chain's."""
        codex = os.environ.get("CODEX_BIN", "")
        if codex:
            codex = os.path.expanduser(os.path.expandvars(codex))
        if not codex or not os.path.exists(codex):
            codex = (shutil.which("codex")
                     or os.path.expanduser("~/.local/bin/codex"))
        instr = os.path.join(cls._sterile_cwd(), "codex-instructions.md")
        try:
            with open(instr, "w") as fh:
                fh.write(SYSTEM_PROMPT)
        except OSError:
            instr = ""
        # Read-only sandbox, never the bypass flag (specs/chessweb.md rule
        # 24f, model-backends.md rule 9): the mover carries untrusted table input,
        # turn, and its prompt carries the sitter's typed name. A chess
        # move needs no hands at all.
        cmd = [codex, "exec", "--ignore-user-config", "--skip-git-repo-check",
               "--sandbox", "read-only",
               "--json", "--color", "never",
               "-m", _codex_resolve(model or cls._model(selfplay)),
               "-c", "model_reasoning_effort=%s" % effort]
        if instr:
            cmd += ["-c", "model_instructions_file=%s" % instr]
        if legal_uci:
            payload = json.dumps(_move_schema(legal_uci),
                                 separators=(",", ":")) + "\n"
            digest = hashlib.sha256(payload.encode()).hexdigest()[:16]
            schema_path = os.path.join(
                cls._sterile_cwd(), "move-schema-%s.json" % digest)
            if not os.path.exists(schema_path):
                tmp = "%s.%d.tmp" % (schema_path, os.getpid())
                try:
                    with open(tmp, "w", encoding="utf-8") as fh:
                        fh.write(payload)
                    os.replace(tmp, schema_path)
                except OSError:
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass
                    raise RuntimeError("could not write the Codex move schema")
            cmd += ["--output-schema", schema_path]
        cmd.append("-")
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

    def _call(self, cmd, env, prompt, timeout=None):
        """(stdout, why-it-failed). why is None on a clean exit and
        'superseded' when a newer position killed or outran the call.
        `timeout` is rule 16g's one bound — the moving side's remaining
        clock, given only for a TIMED job, and a kill there means the flag
        fell mid-think. An untimed call has no ceiling at all (the fixed
        per-call knob is retired, 2026-08-31): it runs until the process
        answers or dies."""
        kill_label = "flag-fell"
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
            why = f"{kill_label}-{timeout:.0f}s"
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
            self._ledger(cmd, env, None, f"{err or ''}\n{out or ''}")
            return out or "", f"exit-{proc.returncode}: {detail[:200]}"
        # The CLI's `--output-format json` result object: the answer is its
        # `result` field, and its usage goes to the token ledger
        # (specs/metrics.md rules 13, 15). Anything that does not parse as
        # that object — a stub, an older CLI — is the whole answer, exactly
        # as the plain-text mode was, and earns no record. Decoding before
        # the move parse is load-bearing: raw JSON is full of hex ids whose
        # substrings read as legal UCI squares.
        try:
            doc = json.loads((out or "").strip())
        except (json.JSONDecodeError, ValueError):
            # Not one object — a codex `--json` event stream is JSONL, and
            # its answer must be lifted out for exactly the same reason.
            text, usage = _codex_jsonl_answer(out)
            if text is not None:
                doc = {"result": text}
                if usage:
                    doc["usage"] = usage
                self._ledger(cmd, env, doc, "")
                return text, None
            return out or "", None
        structured = _structured_move(doc)
        if structured is not None:
            self._ledger(cmd, env, doc, "")
            return structured, None
        if isinstance(doc, dict) and "result" in doc:
            self._ledger(cmd, env, doc, "")
            return str(doc.get("result") or ""), None
        return out or "", None

    @staticmethod
    def _ledger(cmd, env, doc, error_text):
        """Best-effort append to the token ledger; never allowed to change
        the move path's outcome (specs/metrics.md rule 6)."""
        try:
            import token_ledger
            model = ""
            if "--model" in cmd:
                model = cmd[cmd.index("--model") + 1]
            elif "-m" in cmd:
                model = cmd[cmd.index("-m") + 1]
            status = "ok"
            if doc is None:
                status = "refused" if token_ledger.limit_re().search(
                    error_text or "") else "error"
            token_ledger.record_result_object(
                doc, "chess", model=model,
                account=env.get("CLAUDE_CONFIG_DIR", ""), status=status)
        except Exception:
            pass

    # -- the words ---------------------------------------------------------
    def _prompt(self, job, board, rejected=None):
        mem_lines, endorsed, stamp = memory_sections(board)
        if stamp is not None:
            self.metric("similar-context",
                        f"{job['gid']} ply {job['ply']} {stamp}")
        # The reply scan (chess-mover-amendment.md): a candidate that
        # survives the destination-square test is pushed and the opponent's
        # replies scanned one ply deep — the two browser-031 drops and the
        # browser-030 self-block were all printed "safe" by the destination
        # square alone. A scan failure is a prompt with the old two-bucket
        # shape, never a lost move.
        scan = os.environ.get("DESKCRAB_CHESS_REPLY_SCAN", "1") != "0"
        safe, hangs, backed, punished = [], [], [], []
        for m in board.legal_moves:
            loss = material_loss(board, m)
            label = f"{board.san(m)} ({m.uci()})"
            if loss > 0:
                if m.uci() in endorsed:
                    # Rule 14c: a remembered win is never buried in the
                    # concrete-reason pile — both facts ride its own line.
                    backed.append(f"{label} loses {loss} by the count")
                else:
                    hangs.append(f"{label} loses {loss}")
                continue
            worst = (0, None, None)
            if scan:
                try:
                    worst = worst_reply(board, m)
                except Exception:
                    worst = (0, None, None)
            # What the candidate itself banks is compensation: a capture
            # (or a promotion) that gives back less than a pawn of it
            # still reads safe.
            victim = board.piece_type_at(m.to_square)
            comp = PIECE_VALUE[victim] if victim else 0
            if m.promotion:
                comp += PIECE_VALUE[m.promotion] - PIECE_VALUE[chess.PAWN]
            net = worst[0] - comp
            if worst[1] is None or net < 100:
                safe.append(label)
            elif worst[0] >= MATE_LOSS:
                if m.uci() in endorsed:
                    backed.append(f"{label} walks into {worst[1]}, checkmate")
                else:
                    punished.append((worst[0],
                                     f"{label} — {worst[1]} is checkmate"))
            elif m.uci() in endorsed:
                backed.append(f"{label} loses {net} to {worst[1]} "
                              "by the count")
            else:
                punished.append(
                    (net, f"{label} — {worst[1]} {worst[2]}, loses {net}"))
        lines = [f"You are playing {job['side']} against {job['opponent']} "
                 f"(game {job['gid']}, ply {job['ply']}).",
                 f"Position (FEN): {job['fen']}",
                 f"Moves so far: {job['history']}"]
        lines += mem_lines
        # The standing sweep (chess-mover-amendment.md): position-level,
        # once per position, ABOVE the legal-move dump — and always
        # printed, "none" included, so an absent line can only mean the
        # sweep failed. The wording never says "material": the
        # destination-square line below owns that word, and it was
        # demonstrably read as covering the whole board.
        try:
            standing = standing_losses(board)
            named = ", ".join(
                f"{p.symbol().upper()}{chess.square_name(sq)} (loses {loss})"
                for sq, p, loss in standing)
            if standing:
                lines.append("Pieces of yours the opponent can win where "
                             f"they stand: {named}. A move that does not "
                             "address these leaves them there.")
            else:
                lines.append("Pieces of yours the opponent can win where "
                             "they stand: none")
        except Exception:
            pass  # a failed sweep is a prompt without the line, never a lost move
        try:
            lines.append(passed_pawn_line(board))
        except Exception:
            pass  # a failed scan is a prompt without the line, never a lost move
        try:
            guard = trade_guard_line(board)
            if guard:
                lines.append(guard)
        except Exception:
            pass
        lines.append(f"Legal moves that do not lose material on their own "
                     f"square, with no punishing reply found: "
                     f"{', '.join(safe) or 'none'}")
        if backed:
            lines.append("The exchange count reads against these, but the "
                         "memory above holds a winning record with them — "
                         "the record is a concrete reason; verify it on "
                         f"this board: {', '.join(backed)}")
        if hangs:
            lines.append("Legal but the exchange on the destination square "
                         "loses material (centipawns) — play one only with a "
                         f"concrete reason: {', '.join(hangs)}")
        if punished:
            punished.sort(key=lambda t: t[0])
            lines.append("Safe where they land, but the opponent's reply "
                         "punishes them, least bad first — ruled out unless "
                         "you can answer the reply named: "
                         + "; ".join(t for _, t in punished))
        note = (job.get("note") or "").strip()
        if note:
            lines.append(note)
        if rejected:
            lines.append(f"Your previous answer {rejected!r} was rejected "
                         "because it is not one of the allowed tokens below.")
        lines.append("Answer with exactly one token from this UCI whitelist, "
                     "nothing else:")
        lines.append(" ".join(m.uci() for m in board.legal_moves))
        return "\n".join(lines) + "\n"

    @staticmethod
    def _reply_label(text):
        """A safe, short move-like label for logs and the retry prompt."""
        one = " ".join((text or "").split())
        if re.fullmatch(r"[A-Za-z0-9+#=.-]{1,16}", one):
            return one
        return "non-move-text"

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
