#!/usr/bin/env python3
"""betty-chess: persistent correspondence chess against a named opponent.

One JSON file per game under $DESKCRAB_CHESS_DIR/games (default
~/.local/share/deskcrab/chess/games). The move list is the record; the board
is replayed from it on every invocation, so state on disk can never drift
from the rules. Run through the `betty-chess` wrapper, which owns the venv.

Commands: new, list, show, move, undo, status, png, resign, draw, engine.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import chess
import chess.svg

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess_reflex  # position memory; fed on every save, never in the way

CHESS_DIR = Path(os.environ.get("DESKCRAB_CHESS_DIR",
                                Path.home() / ".local/share/deskcrab/chess"))
GAMES_DIR = CHESS_DIR / "games"

LIGHT, DARK = "#F0D9B5", "#B58863"
LIGHT_LAST, DARK_LAST = "#F7EC74", "#DAC431"
CHECK_TINT = "#E06C5A"
FONT_CANDIDATES = [
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
]


class CliError(Exception):
    """A user-facing failure: printed to stderr, exit 1, nothing saved."""


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "opponent"


# ---------------------------------------------------------------- storage

def load_all() -> list[dict]:
    if not GAMES_DIR.is_dir():
        return []
    games = []
    for path in sorted(GAMES_DIR.glob("*.json")):
        try:
            with open(path) as f:
                games.append(json.load(f))
        except (OSError, json.JSONDecodeError) as e:
            print(f"betty-chess: skipping unreadable {path.name}: {e}",
                  file=sys.stderr)
    return games


def save_game(g: dict) -> None:
    GAMES_DIR.mkdir(parents=True, exist_ok=True)
    g["updated"] = now()
    fd, tmp = tempfile.mkstemp(dir=GAMES_DIR, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(g, f, indent=2)
            f.write("\n")
        os.replace(tmp, GAMES_DIR / f"{g['id']}.json")
    except BaseException:
        os.unlink(tmp)
        raise
    # After the file is safely down: a finished game enters reflex memory, a
    # reopened one leaves it. sync_game contains its own failures.
    chess_reflex.sync_game(g)


# Turn metrics for the chess move path (specs/chessweb.md rule 17, kind
# `chess`): where her move's time went, correlated across processes by the
# game id and ply that open every detail. Rule 33's discipline — evidence,
# never control flow; a stamp that cannot be written costs only itself.
METRICS_DIR = os.environ.get("DESKCRAB_METRICS_DIR") or os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "deskcrab", "metrics")


def metric(stage: str, detail: str = "") -> None:
    if os.environ.get("TURN_METRICS", "1") == "0":
        return
    try:
        os.makedirs(METRICS_DIR, exist_ok=True)
        path = os.path.join(METRICS_DIR, time.strftime("%Y-%m-%d") + ".log")
        with open(path, "a") as fh:
            fh.write("%.3f\t%d\t%s\t%s\t%s\n"
                     % (time.time(), os.getpid(), "chess", stage, detail))
    except OSError:
        pass


# ------------------------------------------------------------- session kind
#
# Which kind of claude session is this process running under? Every claude
# invocation registers itself at $DESKCRAB_STATE_PREFIX-sessions/<pid> (see
# session_register in lib/common.sh): one tab-separated line whose FIRST field
# is the kind — 'phone turn', 'desktop turn', 'autonomous wake'. The chess CLI
# runs several process levels below that shell, so the answer comes from
# walking the /proc parent chain upward until a registered pid appears.
# Bounded, and empty-handed on any surprise: a guard that cannot tell must let
# the move through, because the registry binds her sessions, nothing else.

SESSIONS_DIR = Path(
    os.environ.get("DESKCRAB_STATE_PREFIX", "/tmp/deskcrab") + "-sessions")


def _parent_pid(pid: int) -> int:
    """ppid from /proc/<pid>/stat, or 0 when it cannot be read. The comm
    field can itself contain spaces and parens ('(tmux: server)'), so split
    on the LAST ')' — after it the fields are fixed-order, ppid at index 1."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return 0
    fields = stat.rsplit(")", 1)[-1].split()
    try:
        return int(fields[1])
    except (IndexError, ValueError):
        return 0


def session_kind() -> str:
    """The registered kind of the session above this process, or ''."""
    pid = os.getpid()
    for _ in range(24):
        if pid <= 1:
            return ""
        reg = SESSIONS_DIR / str(pid)
        if reg.is_file():
            try:
                return reg.read_text().split("\t", 1)[0].strip()
            except OSError:
                return ""
        pid = _parent_pid(pid)
    return ""


def build_board(g: dict) -> chess.Board:
    board = chess.Board()
    for uci in g["moves"]:
        try:
            board.push(chess.Move.from_uci(uci))
        except (chess.InvalidMoveError, AssertionError) as e:
            raise CliError(f"{g['id']}.json is corrupt at move '{uci}': {e}")
    return board


# ---------------------------------------------------------------- the clock
# specs/chessweb.md rule 22. A game MAY carry a time control, chosen at
# creation; a record without the fields IS an untimed game, which is how
# every game recorded before the rule keeps its meaning unread. The clock is
# three stored facts — per-side remaining ms, the wall-clock second the
# current turn began, and the flag once one falls — read against time.time(),
# so a bridge that dies mid-think comes back to a clock that kept running.

TIME_CONTROLS = {  # name -> (speed, base ms, Fischer increment ms per move)
    "1+0": ("bullet", 60_000, 0),
    "2+1": ("bullet", 120_000, 1_000),
    "3+2": ("blitz", 180_000, 2_000),
    "5+0": ("blitz", 300_000, 0),
    "10+0": ("rapid", 600_000, 0),
    "15+10": ("rapid", 900_000, 10_000),
}


def make_time_control(name):
    """(time_control, clock) fields for a NEW game, or (None, None) for
    untimed. Raises CliError on a name outside the standard set."""
    if not name or name == "untimed":
        return None, None
    if name not in TIME_CONTROLS:
        raise CliError(f"unknown time control '{name}' — one of: "
                       f"{', '.join(TIME_CONTROLS)}, untimed")
    speed, base, inc = TIME_CONTROLS[name]
    return ({"name": name, "speed": speed, "base_ms": base, "inc_ms": inc},
            {"white_ms": base, "black_ms": base, "turn_started": None})


def _clock_armed(g: dict) -> bool:
    """Is the side to move's clock actually running? Each side's first move
    is free (rule 22a): charging — and flagging — begin at ply 2."""
    tc, ck = g.get("time_control"), g.get("clock")
    return bool(tc and ck and ck.get("turn_started") is not None
                and len(g["moves"]) >= 2)


def flag_fallen(g: dict, board: chess.Board, now: float = None) -> str | None:
    """The side that has lost on time: the recorded flag_fell, else judged
    live off the stored clock and the wall clock (rule 22b). None while
    nobody has flagged, the game is otherwise over, or there is no clock."""
    if g.get("flag_fell"):
        return g["flag_fell"]
    if g.get("resigned_by") or g.get("draw_agreed") or board.is_game_over():
        return None
    if not _clock_armed(g):
        return None
    now = time.time() if now is None else now
    side = "white" if board.turn == chess.WHITE else "black"
    spent = (now - g["clock"]["turn_started"]) * 1000
    return side if g["clock"].get(f"{side}_ms", 0) - spent <= 0 else None


def _flag_state(g: dict, board: chess.Board, side: str):
    """(key, desc, result) for a fallen flag: the flagged side loses, unless
    the winner cannot mate — insufficient material is a draw (rule 22d)."""
    winner = "black" if side == "white" else "white"
    colour = chess.WHITE if winner == "white" else chess.BLACK
    if board.has_insufficient_material(colour):
        return ("draw", f"{side} lost on time, but {winner} has insufficient "
                        f"material — draw", "1/2-1/2")
    return ("flag", f"{side} lost on time — {winner} wins",
            "1-0" if winner == "white" else "0-1")


def clock_move(g: dict, now: float = None) -> None:
    """Charge the clock for the move JUST APPENDED to g['moves'] (not yet
    saved): the mover's elapsed think comes off their remaining milliseconds
    (floored at zero) and the increment goes back on — from each side's
    second move; both first moves are free (rule 22a) — and the turn clock
    restarts for the other side. One implementation for every record path;
    a game without a time control is untouched."""
    tc, ck = g.get("time_control"), g.get("clock")
    if not tc or not ck:
        return
    now = time.time() if now is None else now
    ply = len(g["moves"]) - 1  # the move just appended
    if ply >= 2 and ck.get("turn_started") is not None:
        mover = "white" if ply % 2 == 0 else "black"
        spent = max(0, int((now - ck["turn_started"]) * 1000))
        ck[mover + "_ms"] = (max(0, ck.get(mover + "_ms", 0) - spent)
                             + tc.get("inc_ms", 0))
    ck["turn_started"] = now


def clock_remaining(g: dict, board: chess.Board, now: float = None):
    """{'white_ms', 'black_ms', 'running'} live at `now` — the running
    side's figure with the current think already deducted, a flagged side
    at zero — or None when the game has no clock (rule 22f)."""
    tc, ck = g.get("time_control"), g.get("clock")
    if not tc or not ck:
        return None
    now = time.time() if now is None else now
    out = {"white_ms": ck.get("white_ms", 0), "black_ms": ck.get("black_ms", 0),
           "running": None}
    flagged = flag_fallen(g, board, now)
    if flagged:
        out[flagged + "_ms"] = 0
        return out
    if (_clock_armed(g) and not g.get("resigned_by")
            and not g.get("draw_agreed") and not board.is_game_over()):
        side = "white" if board.turn == chess.WHITE else "black"
        spent = max(0, int((now - ck["turn_started"]) * 1000))
        out[side + "_ms"] = max(0, out[side + "_ms"] - spent)
        out["running"] = side
    return out


def clock_line(g: dict, board: chess.Board) -> str | None:
    """The human clock line for status: control, both remaining, whose
    clock runs. None for an untimed game."""
    tc = g.get("time_control")
    rem = clock_remaining(g, board)
    if not tc or rem is None:
        return None
    def fmt(ms):
        s = ms / 1000
        return f"{int(s // 60)}:{s % 60:04.1f}"
    tail = f" ({rem['running']}'s clock running)" if rem["running"] else ""
    return (f"clock: {tc['name']} {tc['speed']} — "
            f"white {fmt(rem['white_ms'])}, black {fmt(rem['black_ms'])}"
            f"{tail}")


def compute_state(g: dict, board: chess.Board,
                  now: float = None) -> tuple[str, str, str]:
    """(key, human description, result) — key is 'active' or a game-over kind.
    Time-aware (rule 22b): a fallen flag, recorded or judged live off the
    stored clock, is a finished game to every reader."""
    if g.get("resigned_by"):
        side = g["resigned_by"]
        return ("resigned", f"{side} resigned",
                "0-1" if side == "white" else "1-0")
    if g.get("draw_agreed"):
        return ("draw", "draw agreed", "1/2-1/2")
    if g.get("flag_fell"):
        return _flag_state(g, board, g["flag_fell"])
    if board.is_checkmate():
        winner = "black" if board.turn == chess.WHITE else "white"
        return ("checkmate", f"checkmate — {winner} wins",
                "0-1" if winner == "black" else "1-0")
    if board.is_stalemate():
        return ("stalemate", "stalemate", "1/2-1/2")
    if board.is_insufficient_material():
        return ("draw", "draw — insufficient material", "1/2-1/2")
    if board.is_seventyfive_moves():
        return ("draw", "draw — seventy-five-move rule", "1/2-1/2")
    if board.is_fivefold_repetition():
        return ("draw", "draw — fivefold repetition", "1/2-1/2")
    live = flag_fallen(g, board, now)
    if live:
        return _flag_state(g, board, live)
    turn = "white" if board.turn == chess.WHITE else "black"
    desc = f"{turn} to move" + (", in check" if board.is_check() else "")
    return ("active", desc, "*")


def settle_flag(g: dict, board: chess.Board) -> bool:
    """Make a live-derived flag fall durable: record flag_fell and save
    (which is also what hands the finished game to reflex ingest). True
    when this call wrote it. Rule 22c: recording is the bridge's job, and
    the bridge calls this."""
    side = flag_fallen(g, board)
    if side is None or g.get("flag_fell"):
        return False
    g["flag_fell"] = side
    save_game(g)
    return True


def resolve_game(spec: str | None) -> dict:
    games = load_all()
    if not games:
        raise CliError("no games yet — start one with: betty-chess new <opponent>")

    def is_active(g):
        return compute_state(g, build_board(g))[0] == "active"

    if spec:
        exact = [g for g in games if g["id"] == spec]
        if exact:
            return exact[0]
        s = slugify(spec)
        matched = [g for g in games
                   if slugify(g["opponent"]) == s or g["id"].startswith(s)]
        if not matched:
            raise CliError(f"no game matches '{spec}' — see: betty-chess list")
        active = [g for g in matched if is_active(g)]
        pool = active or matched
        if len(pool) > 1:
            ids = ", ".join(g["id"] for g in pool)
            raise CliError(f"'{spec}' is ambiguous between: {ids}")
        return pool[0]

    active = [g for g in games if is_active(g)]
    if len(active) == 1:
        return active[0]
    if not active:
        # Every game is finished: the last one played is what anyone means by
        # "the game" — a post-mortem is exactly when you want to look at it.
        return max(games, key=lambda g: (g.get("updated") or "", g["id"]))
    ids = ", ".join(g["id"] for g in active)
    raise CliError(f"several active games ({ids}) — name one")


def side_name(g: dict, colour: str) -> str:
    return "you" if g["my_side"] == colour else g["opponent"]


# ---------------------------------------------------------------- rendering

def render_unicode(g: dict, board: chess.Board) -> str:
    flip = g["my_side"] == "black"
    ranks = range(8) if flip else range(7, -1, -1)
    files = range(7, -1, -1) if flip else range(8)
    file_row = "   " + " ".join(chess.FILE_NAMES[f] for f in files)
    lines = [file_row]
    for r in ranks:
        cells = []
        for f in files:
            piece = board.piece_at(chess.square(f, r))
            cells.append(piece.unicode_symbol() if piece else "·")
        lines.append(f" {r + 1} " + " ".join(cells) + f" {r + 1}")
    lines.append(file_row)
    return "\n".join(lines)


def board_svg(g: dict, board: chess.Board) -> str:
    last = board.peek() if board.move_stack else None
    check = board.king(board.turn) if board.is_check() else None
    orientation = chess.BLACK if g["my_side"] == "black" else chess.WHITE
    return chess.svg.board(board, orientation=orientation, lastmove=last,
                           check=check, size=720)


def render_png_pil(g: dict, board: chess.Board, out: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    sq, border = 90, 32
    size = 8 * sq + 2 * border
    font_path = next((p for p in FONT_CANDIDATES if os.path.exists(p)), None)
    if font_path is None:
        raise CliError("PIL fallback needs a font with chess glyphs; none of "
                       f"these exist: {', '.join(FONT_CANDIDATES)}")
    piece_font = ImageFont.truetype(font_path, int(sq * 0.78))
    label_font = ImageFont.truetype(font_path, 18)

    flip = g["my_side"] == "black"
    last = board.peek() if board.move_stack else None
    last_squares = {last.from_square, last.to_square} if last else set()
    check_sq = board.king(board.turn) if board.is_check() else None

    img = Image.new("RGB", (size, size), "#312E2B")
    draw = ImageDraw.Draw(img)
    for rank in range(8):
        for file in range(8):
            square = chess.square(file, rank)
            col = 7 - file if flip else file
            row = rank if flip else 7 - rank
            x, y = border + col * sq, border + row * sq
            light = (file + rank) % 2 == 1
            if square == check_sq:
                fill = CHECK_TINT
            elif square in last_squares:
                fill = LIGHT_LAST if light else DARK_LAST
            else:
                fill = LIGHT if light else DARK
            draw.rectangle([x, y, x + sq, y + sq], fill=fill)
            piece = board.piece_at(square)
            if piece:
                # Solid glyphs for both sides; colour comes from fill+stroke,
                # which stays legible on both square colours.
                glyph = chess.UNICODE_PIECE_SYMBOLS[piece.symbol().lower()]
                white = piece.color == chess.WHITE
                draw.text((x + sq / 2, y + sq / 2), glyph,
                          font=piece_font, anchor="mm",
                          fill="#FFFFFF" if white else "#000000",
                          stroke_width=3,
                          stroke_fill="#000000" if white else "#FFFFFF")
    for i in range(8):
        file = 7 - i if flip else i
        rank = i if flip else 7 - i
        cx = border + i * sq + sq // 2
        cy = border + i * sq + sq // 2
        draw.text((cx, size - border // 2), chess.FILE_NAMES[file],
                  font=label_font, anchor="mm", fill="#C8C8C8")
        draw.text((border // 2, cy), chess.RANK_NAMES[rank],
                  font=label_font, anchor="mm", fill="#C8C8C8")
    img.save(out, "PNG")


def render_png(g: dict, board: chess.Board, out: Path) -> str:
    """Write a PNG of the position; returns the renderer that produced it."""
    svg = board_svg(g, board)
    prefer = os.environ.get("CRAB_CHESS_RENDERER", "auto")

    if prefer in ("auto", "rsvg") and shutil.which("rsvg-convert"):
        subprocess.run(["rsvg-convert", "-o", str(out)],
                       input=svg.encode(), check=True)
        return "rsvg-convert"
    if prefer in ("auto", "cairosvg"):
        try:
            import cairosvg
            cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out))
            return "cairosvg"
        except ImportError:
            if prefer == "cairosvg":
                raise CliError("cairosvg requested but not importable")
    try:
        render_png_pil(g, board, out)
        return "pil"
    except ImportError:
        raise CliError("no PNG renderer: rsvg-convert missing, cairosvg and "
                       "pillow not importable in the venv")


def default_png_path(g: dict) -> Path:
    return Path(tempfile.gettempdir()) / f"betty-chess-{g['id']}.png"


# ---------------------------------------------------------------- moves

def parse_move(board: chess.Board, text: str) -> chess.Move:
    text = text.strip()
    if re.fullmatch(r"0-0(-0)?[+#]?", text):
        text = text.replace("0", "O")
    san_was_illegal = False
    try:
        return board.parse_san(text)
    except chess.AmbiguousMoveError:
        raise CliError(f"'{text}' is ambiguous — more than one piece can make "
                       "that move; add the file or rank (e.g. Nbd2, R1e2)")
    except chess.IllegalMoveError:
        san_was_illegal = True
    except chess.InvalidMoveError:
        pass
    try:
        move = chess.Move.from_uci(text.lower())
    except chess.InvalidMoveError:
        if san_was_illegal:
            raise CliError(f"illegal move: {text}")
        raise CliError(f"cannot read '{text}' as a chess move — use SAN "
                       "(Nf3, exd5, O-O, e8=Q) or coordinates (g1f3, e7e8q)")
    if move not in board.legal_moves:
        raise CliError(f"illegal move: {text}")
    return move


def moves_since(g: dict, ply: int) -> str:
    """SAN of the plies played after `ply`, for telling a stale caller what it
    missed. Empty string when nothing was played."""
    board = chess.Board()
    played = []
    for i, uci in enumerate(g["moves"]):
        move = chess.Move.from_uci(uci)
        if i >= ply:
            played.append(board.san(move))
        board.push(move)
    return " ".join(played)


def check_expectation(g: dict, board: chess.Board, ply, fen) -> None:
    """Refuse to act when the caller was answering an older board.

    A wake carrying a position is a photograph: by the time it reaches her the
    game may have moved on, and a perfectly legal move against the wrong board
    is a blunder nobody chose. See rule 15 in specs/chessweb.md.
    """
    have = len(g["moves"])
    if ply is not None and ply != have:
        if ply > have:
            raise CliError(
                f"{g['id']}: you expected ply {ply}, but only {have} have been "
                f"played — that position never happened. Read the board: "
                f"betty-chess show {g['id']}")
        since = moves_since(g, ply) or "(nothing)"
        raise CliError(
            f"{g['id']}: the board has moved on — you expected ply {ply}, it "
            f"is at ply {have}. Played since: {since}. Refusing the move. "
            f"Read the board and think again: betty-chess show {g['id']}")
    if fen is not None:
        want = fen.strip()
        # Compare the position proper; halfmove/fullmove counters and a stale
        # en-passant square are not what the caller is claiming to have seen.
        if want.split()[:4] != board.fen().split()[:4]:
            raise CliError(
                f"{g['id']}: the board has moved on — the FEN you expected is "
                f"not the position on disk (now at ply {have}: {board.fen()}). "
                f"Refusing the move. Read the board: betty-chess show {g['id']}")


def guard_resident_mover(g: dict, board: chess.Board, force: bool) -> None:
    """Refuse to play her side of a browser game from the command line.

    Browser games are answered in-process by the resident mover
    (specs/chessweb.md rule 16), which pushes its reply straight into the
    store and never comes through this CLI. A hand-typed or wake-driven
    `betty-chess move` on one is a second mover racing the first, and rule
    16d guarantees one of the two answers is discarded as stale: twice on
    the night of 2026-08-10 a wake did exactly that while the mover was
    mid-think, and the game visibly played worse. See rule 15b. Mirrored
    opponent moves — the side to move not hers — pass untouched.
    """
    if force or g.get("opponent") != "browser":
        return
    mover = "white" if board.turn == chess.WHITE else "black"
    if mover != g.get("my_side"):
        return
    raise CliError(
        f"{g['id']} is a browser game — the resident mover plays her side "
        f"there, and a move from the command line races it: whichever "
        f"answer lands second is discarded as stale. Use --force only if "
        f"the mover is known to be down.")


def raise_turn_conflict(g: dict, board: chess.Board, text: str,
                        err: CliError) -> None:
    """cmd_move's parse failed. When the side to move is not hers, the
    likeliest truth is not a bad move but a stale photograph: another hand —
    the resident mover, or a second session of her — already answered this
    position, and the turn has passed. Say THAT, naming whose move it is
    (specs/chessweb.md rule 15). On 2026-08-10 two of her sessions answered
    one board with the same move, and the loser was told "illegal move: Nf3"
    as if she could not read a board. Re-raises the original error when it
    really is her turn."""
    mover = "white" if board.turn == chess.WHITE else "black"
    if mover == g.get("my_side"):
        raise err
    # Text that is not chess-shaped at all keeps its own error: "turn
    # conflict" over gibberish would send her hunting a race that never was.
    t0 = text.strip()
    shaped = re.fullmatch(
        r"[KQRBN]?[a-h]?[1-8]?x?[a-h][1-8](=?[QRBN])?[+#]?"
        r"|[O0]-[O0](-[O0])?[+#]?", t0, re.IGNORECASE)
    if not shaped:
        try:
            chess.Move.from_uci(t0.lower())
        except chess.InvalidMoveError:
            raise err
    ply = len(g["moves"])
    already = ""
    if g["moves"]:
        prev = chess.Board()
        for uci in g["moves"][:-1]:
            prev.push(chess.Move.from_uci(uci))
        t = text.strip()
        if re.fullmatch(r"0-0(-0)?[+#]?", t):
            t = t.replace("0", "O")
        cand = None
        try:
            cand = prev.parse_san(t)
        except ValueError:
            try:
                cand = chess.Move.from_uci(t.lower())
            except chess.InvalidMoveError:
                cand = None
        if cand == chess.Move.from_uci(g["moves"][-1]):
            already = (f" Your '{text}' is already on the board — another "
                       f"hand played it at ply {ply - 1}.")
    raise CliError(
        f"{g['id']}: turn conflict — it is {mover}'s move "
        f"({side_name(g, mover)}), not yours; the game is at ply "
        f"{ply}.{already} Read the board and think again: "
        f"betty-chess show {g['id']}")


def history(board_moves: list[str]) -> str:
    if not board_moves:
        return "(no moves yet)"
    return chess.Board().variation_san(
        [chess.Move.from_uci(u) for u in board_moves])


def legal_line(board: chess.Board) -> str:
    """Every legal move for the side to play, in SAN, sorted.

    Printed with the board (chess-reflex.md rule 15) because counting escape
    squares off the drawing loses games: a position that was already mate read
    as two flights out of the ASCII art. The library knows exactly; make it say
    so unasked.
    """
    sans = sorted(board.san(m) for m in board.legal_moves)
    return f"legal ({len(sans)}): {' '.join(sans)}"


def print_position(g: dict, board: chess.Board) -> None:
    key, desc, result = compute_state(g, board)
    print(render_unicode(g, board))
    if board.move_stack:
        last_board = chess.Board()
        for uci in g["moves"][:-1]:
            last_board.push(chess.Move.from_uci(uci))
        print(f"last move: {last_board.san(board.peek())}")
    if key == "active":
        mover = "white" if board.turn == chess.WHITE else "black"
        print(f"{desc} ({side_name(g, mover)}), move "
              f"{board.fullmove_number}, ply {len(g['moves'])}")
        print(legal_line(board))
    else:
        print(f"game over: {desc}  [{result}]")


# ---------------------------------------------------------------- commands

def cmd_new(args):
    tc, ck = make_time_control(args.time_control)
    slug = slugify(args.opponent)
    taken = {g["id"] for g in load_all()}
    n = 1
    while f"{slug}-{n:03d}" in taken:
        n += 1
    g = {
        "id": f"{slug}-{n:03d}",
        "opponent": args.opponent,
        "my_side": args.side,
        "moves": [],
        "resigned_by": None,
        "draw_agreed": False,
        "engine_level": args.engine_level,
        "created": now(),
    }
    if tc:
        g["time_control"] = tc
        g["clock"] = ck
        g["flag_fell"] = None
    save_game(g)
    opp_side = "black" if args.side == "white" else "white"
    print(f"{g['id']}: you are {args.side}, {args.opponent} is {opp_side}")
    if tc:
        print(f"time control: {tc['name']} {tc['speed']} — "
              f"{tc['base_ms'] // 60000} min + {tc['inc_ms'] // 1000}s/move")
    print_position(g, build_board(g))


def cmd_list(args):
    games = load_all()
    if not games:
        print("no games — betty-chess new <opponent>")
        return
    games.sort(key=lambda g: g.get("updated", ""), reverse=True)
    for g in games:
        board = build_board(g)
        _, desc, result = compute_state(g, board)
        white = side_name(g, "white")
        black = side_name(g, "black")
        tag = desc if result == "*" else f"{desc} [{result}]"
        tc = g.get("time_control")
        control = tc["name"] if tc else "untimed"
        print(f"{g['id']:<16} {white} v {black:<12} "
              f"{len(g['moves']):>3} plies  {control:<8} {tag}")


def cmd_show(args):
    g = resolve_game(args.game)
    board = build_board(g)
    print(f"{g['id']}: you ({g['my_side']}) v {g['opponent']}")
    print_position(g, board)
    if args.png is not None:
        out = Path(args.png) if args.png else default_png_path(g)
        renderer = render_png(g, board, out)
        print(f"png: {out} ({renderer})")


def cmd_png(args):
    g = resolve_game(args.game)
    board = build_board(g)
    out = Path(args.out) if args.out else default_png_path(g)
    renderer = render_png(g, board, out)
    print(f"{out} ({renderer})")


def cmd_move(args):
    # Before anything else — before even naming the game: a move arriving
    # from an autonomous wake is refused outright (specs/chessweb.md rule
    # 20). On 2026-08-10 a wake mirrored a move into a live game two minutes
    # after a written conduct rule said the mover plays, not the wake; the
    # mover's own answer for that ply came back, was discarded as stale, and
    # a knight was lost for nothing. Prose did not hold, so the code does.
    if (session_kind() == "autonomous wake"
            and os.environ.get("DESKCRAB_CHESS_ALLOW_WAKE_MOVE") != "1"):
        raise CliError(
            "this session is an autonomous wake, and a wake may look at the "
            "board but not play on it — the resident mover owns the move, "
            "and a wake that plays races it (specs/chessweb.md rule 20). "
            "show, status, reflex and similar all still work. If a human "
            "explicitly asked this wake to place this exact move, "
            "DESKCRAB_CHESS_ALLOW_WAKE_MOVE=1 is the override.")
    if len(args.words) == 1:
        spec, text = None, args.words[0]
    elif len(args.words) == 2:
        spec, text = args.words
    else:
        raise CliError("usage: betty-chess move [game] <move>")
    g = resolve_game(spec)
    board = build_board(g)
    check_expectation(g, board, args.expect_ply, args.expect_fen)
    guard_resident_mover(g, board, args.force)
    key, desc, _ = compute_state(g, board)
    if key != "active":
        raise CliError(f"{g['id']} is over ({desc}) — undo to reopen it, "
                       "or start a new game")
    try:
        move = parse_move(board, text)
    except CliError as err:
        # A move that fails while the turn is not hers is a turn conflict,
        # not an "illegal move" — name whose move it actually is.
        raise_turn_conflict(g, board, text, err)
    san = board.san(move)
    mover = "white" if board.turn == chess.WHITE else "black"
    ply = len(g["moves"])
    board.push(move)
    g["moves"].append(move.uci())
    clock_move(g)
    save_game(g)
    if mover == g.get("my_side"):
        metric("move-played", f"{g['id']} ply {ply} {san} cli")
    print(f"{g['id']}: played {san}")
    print_position(g, board)


def cmd_undo(args):
    g = resolve_game(args.game)
    if (not g["moves"] and not g["resigned_by"] and not g["draw_agreed"]
            and not g.get("flag_fell")):
        raise CliError(f"{g['id']}: nothing to undo")
    if g["resigned_by"] or g["draw_agreed"] or g.get("flag_fell"):
        # First undo after a resignation, agreed draw or fallen flag reopens
        # the game without touching the moves (rule 22g).
        g["resigned_by"] = None
        g["draw_agreed"] = False
        g["flag_fell"] = None
        undone = "the game-ending agreement"
    else:
        n = min(args.plies, len(g["moves"]))
        del g["moves"][-n:]
        undone = f"{n} ply" if n == 1 else f"{n} plies"
    if g.get("clock"):
        # No per-move time history exists to replay, so the sides resume
        # with the balances they had; only the turn clock restarts (22g).
        g["clock"]["turn_started"] = time.time()
    save_game(g)
    print(f"{g['id']}: undid {undone}")
    print_position(g, build_board(g))


def cmd_status(args):
    g = resolve_game(args.game)
    board = build_board(g)
    key, desc, result = compute_state(g, board)
    print(f"{g['id']}: you ({g['my_side']}) v {g['opponent']} "
          f"({'black' if g['my_side'] == 'white' else 'white'})")
    if key == "active":
        mover = "white" if board.turn == chess.WHITE else "black"
        print(f"turn: {mover} ({side_name(g, mover)}), "
              f"move {board.fullmove_number}, ply {len(g['moves'])}")
        print(f"state: {desc}")
        claims = []
        if board.can_claim_threefold_repetition():
            claims.append("threefold repetition")
        if board.can_claim_fifty_moves():
            claims.append("fifty-move rule")
        if claims:
            print(f"draw claimable: {', '.join(claims)}")
        print(legal_line(board))
    else:
        print(f"state: {desc}  [{result}]")
    line = clock_line(g, board)
    if line:
        # The mover reads its remaining time off this line (rule 22f).
        print(line)
    print(f"history: {history(g['moves'])}")
    print(f"fen: {board.fen()}")
    if g.get("engine_level") is not None:
        print(f"engine level: {g['engine_level']}")


def cmd_resign(args):
    g = resolve_game(args.game)
    board = build_board(g)
    key, desc, _ = compute_state(g, board)
    if key != "active":
        raise CliError(f"{g['id']} is already over ({desc})")
    side = args.side or g["my_side"]
    g["resigned_by"] = side
    save_game(g)
    _, desc, result = compute_state(g, board)
    print(f"{g['id']}: {side_name(g, side)} ({side}) resigns  [{result}]")


def cmd_draw(args):
    g = resolve_game(args.game)
    board = build_board(g)
    key, desc, _ = compute_state(g, board)
    if key != "active":
        raise CliError(f"{g['id']} is already over ({desc})")
    g["draw_agreed"] = True
    save_game(g)
    print(f"{g['id']}: draw agreed  [1/2-1/2]")


def cmd_engine(args):
    # CRAB_CHESS_ENGINE names any UCI binary; stockfish is only the default.
    named = os.environ.get("CRAB_CHESS_ENGINE")
    path = shutil.which(named) if named else shutil.which("stockfish")
    if not path:
        which = named or "stockfish"
        raise CliError(f"{which} is not on PATH — the engine opponent is "
                       "optional and currently unavailable; human play is "
                       "unaffected (set CRAB_CHESS_ENGINE to another UCI "
                       "engine if you have one)")
    import chess.engine
    g = resolve_game(args.game)
    board = build_board(g)
    key, desc, _ = compute_state(g, board)
    if key != "active":
        raise CliError(f"{g['id']} is over ({desc})")
    if args.level is not None:
        g["engine_level"] = args.level
    level = g.get("engine_level")
    with chess.engine.SimpleEngine.popen_uci(path) as engine:
        if level is not None:
            engine.configure({"Skill Level": max(0, min(20, level))})
        played = engine.play(board, chess.engine.Limit(time=1.0))
    san = board.san(played.move)
    board.push(played.move)
    g["moves"].append(played.move.uci())
    clock_move(g)
    save_game(g)
    lvl = f" (skill {level})" if level is not None else ""
    print(f"{g['id']}: engine{lvl} plays {san}")
    print_position(g, board)


def board_from_args(words: list[str], usage: str) -> chess.Board:
    """A FEN if it reads as one, otherwise a game id/opponent (or nothing at
    all, meaning the one active game). Every other subcommand takes a game id;
    reflex and similar refusing to was a step I skipped because it errored."""
    spec = " ".join(words).strip()
    if spec:
        try:
            return chess.Board(spec)
        except ValueError as fen_error:
            try:
                return build_board(resolve_game(spec))
            except CliError:
                raise CliError(f"cannot read that as a FEN ({fen_error}), and "
                               f"no game matches '{spec}' — {usage}")
    return build_board(resolve_game(None))


def cmd_reflex(args):
    if args.backfill:
        done, active = chess_reflex.backfill(load_all())
        print(f"reflex: ingested {done} finished game(s), "
              f"left {active} active one(s) alone ({chess_reflex.db_path()})")
        return
    if args.seed_book:
        import chess_book
        r = chess_book.seed()
        print(f"reflex: book seeded — {r['lines']} lines, {r['moves']} moves; "
              f"positions {r['positions_before']} -> {r['positions_after']} "
              f"({chess_reflex.db_path()})")
        return
    board = board_from_args(
        args.fen, "usage: betty-chess reflex [<fen>|<game>] | reflex "
                  "--backfill | reflex --seed-book")
    candidates = chess_reflex.lookup(board.fen())
    if not candidates:
        raise CliError("no memory of this position")
    for c in candidates:
        try:
            san = board.san(chess.Move.from_uci(c["move"]))
        except (chess.InvalidMoveError, chess.IllegalMoveError, AssertionError):
            san = "??"  # remembered from a position this board disagrees with
        book = f"  book {c['book']}" if c["book"] else ""
        print(f"{san:<8} {c['move']:<6} games {c['n']:>3}  "
              f"{c['wins']}-{c['draws']}-{c['losses']}  "
              f"score {c['score']:.2f}{book}")
    best = chess_reflex.best_move(board.fen(), board)
    if best:
        san = board.san(chess.Move.from_uci(best["move"]))
        why = (f"seen {best['n']}x, score {best['score']:.2f}" if best["n"]
               else f"book, {best['book']} line(s)")
        print(f"reflex: would play {san} ({why})")
    else:
        print(f"reflex: not confident enough — needs "
              f"{chess_reflex.MIN_GAMES} game(s) at score "
              f"{chess_reflex.MIN_SCORE:.2f}; think instead")


def cmd_similar(args):
    board = board_from_args(
        args.fen, "usage: betty-chess similar [<fen>|<game>] [-k N]")
    import chess_similar
    hits = chess_similar.similar(board.fen(), k=args.k)
    if not hits:
        raise CliError("no stored positions to compare against — finish a "
                       "game, or run: betty-chess reflex --backfill")
    for h in hits:
        tag = "exact" if h["exact"] else f"{h['similarity']:.2f} "
        print(f"{tag:<6} {h['san']:<8} as {h['colour']:<6} "
              f"{h['wins']}-{h['draws']}-{h['losses']}  "
              f"{h['game_id']} ply {h['ply']}")
    note = chess_similar.reason_note(board)
    if not note:
        print("(nothing near enough to brief a wake with — expected while "
              "the store is small)")


# ---------------------------------------------------------------- entry

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="betty-chess",
        description="Correspondence chess with state on disk. Most commands "
                    "take an optional game id or opponent name; with one "
                    "active game it is inferred.")
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("new", help="start a game against an opponent")
    sp.add_argument("opponent")
    sp.add_argument("--as", dest="side", choices=["white", "black"],
                    default="white", help="which side you play (default white)")
    sp.add_argument("--engine-level", type=int, default=None,
                    help="stockfish skill 0-20, if you want engine replies")
    sp.add_argument("--time-control", default="untimed",
                    metavar="NAME",
                    help="a chess clock for the game: one of "
                         f"{', '.join(TIME_CONTROLS)} (base+increment), or "
                         "untimed (the default, no clock at all)")
    sp.set_defaults(func=cmd_new)

    sp = sub.add_parser("list", help="all games, newest first")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("show", help="print the board")
    sp.add_argument("game", nargs="?")
    sp.add_argument("--png", nargs="?", const="", default=None,
                    metavar="PATH", help="also render a PNG (default /tmp)")
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("png", help="render the board to a PNG")
    sp.add_argument("game", nargs="?")
    sp.add_argument("-o", "--out", default=None)
    sp.set_defaults(func=cmd_png)

    sp = sub.add_parser("move", help="play a move (SAN or coordinates)")
    sp.add_argument("words", nargs="+", metavar="[game] move")
    sp.add_argument("--expect-ply", type=int, default=None, metavar="N",
                    help="the ply count you believed you were answering; "
                         "the move is refused if the game has moved on")
    sp.add_argument("--expect-fen", default=None, metavar="FEN",
                    help="likewise, but naming the position itself")
    sp.add_argument("--force", action="store_true", default=False,
                    help="override the resident-mover guard: play her side "
                         "of a browser game from the command line anyway "
                         "(only when the mover is known to be down)")
    sp.set_defaults(func=cmd_move)

    sp = sub.add_parser("undo", help="take back plies (or a resignation)")
    sp.add_argument("game", nargs="?")
    sp.add_argument("-n", "--plies", type=int, default=1)
    sp.set_defaults(func=cmd_undo)

    sp = sub.add_parser("status", help="turn, state, history, FEN")
    sp.add_argument("game", nargs="?")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("resign", help="resign (your side unless --side)")
    sp.add_argument("game", nargs="?")
    sp.add_argument("--side", choices=["white", "black"])
    sp.set_defaults(func=cmd_resign)

    sp = sub.add_parser("draw", help="record an agreed draw")
    sp.add_argument("game", nargs="?")
    sp.set_defaults(func=cmd_draw)

    sp = sub.add_parser("engine", help="let stockfish move for the side to play")
    sp.add_argument("game", nargs="?")
    sp.add_argument("--level", type=int, help="stockfish skill 0-20, remembered")
    sp.set_defaults(func=cmd_engine)

    sp = sub.add_parser("reflex",
                        help="what memory says about a position "
                             "(specs/chess-reflex.md)")
    sp.add_argument("fen", nargs="*",
                    help="a FEN or a game id/opponent (default: the active game); "
                         "candidates come back ranked")
    sp.add_argument("--backfill", action="store_true",
                    help="ingest every finished game already on disk")
    sp.add_argument("--seed-book", action="store_true",
                    help="(re)write the opening book of mainline theory")
    sp.set_defaults(func=cmd_reflex)

    sp = sub.add_parser("similar",
                        help="stored positions most like a FEN "
                             "(specs/chess-reflex.md rules 10-14)")
    sp.add_argument("fen", nargs="*",
                    help="a FEN or a game id/opponent (default: the active "
                         "game); neighbours come back nearest "
                         "first with the move played and the mover's W-D-L")
    sp.add_argument("-k", type=int, default=6, help="how many (default 6)")
    sp.set_defaults(func=cmd_similar)

    args = p.parse_args(argv)
    try:
        args.func(args)
    except CliError as e:
        print(f"betty-chess: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
