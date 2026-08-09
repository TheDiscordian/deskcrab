#!/usr/bin/env python3
"""crab-chess: persistent correspondence chess against a named opponent.

One JSON file per game under $DESKCRAB_CHESS_DIR/games (default
~/.local/share/deskcrab/chess/games). The move list is the record; the board
is replayed from it on every invocation, so state on disk can never drift
from the rules. Run through the `crab-chess` wrapper, which owns the venv.

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
from datetime import datetime, timezone
from pathlib import Path

import chess
import chess.svg

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
            print(f"crab-chess: skipping unreadable {path.name}: {e}",
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


def build_board(g: dict) -> chess.Board:
    board = chess.Board()
    for uci in g["moves"]:
        try:
            board.push(chess.Move.from_uci(uci))
        except (chess.InvalidMoveError, AssertionError) as e:
            raise CliError(f"{g['id']}.json is corrupt at move '{uci}': {e}")
    return board


def compute_state(g: dict, board: chess.Board) -> tuple[str, str, str]:
    """(key, human description, result) — key is 'active' or a game-over kind."""
    if g.get("resigned_by"):
        side = g["resigned_by"]
        return ("resigned", f"{side} resigned",
                "0-1" if side == "white" else "1-0")
    if g.get("draw_agreed"):
        return ("draw", "draw agreed", "1/2-1/2")
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
    turn = "white" if board.turn == chess.WHITE else "black"
    desc = f"{turn} to move" + (", in check" if board.is_check() else "")
    return ("active", desc, "*")


def resolve_game(spec: str | None) -> dict:
    games = load_all()
    if not games:
        raise CliError("no games yet — start one with: crab-chess new <opponent>")

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
            raise CliError(f"no game matches '{spec}' — see: crab-chess list")
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
    return Path(tempfile.gettempdir()) / f"crab-chess-{g['id']}.png"


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


def history(board_moves: list[str]) -> str:
    if not board_moves:
        return "(no moves yet)"
    return chess.Board().variation_san(
        [chess.Move.from_uci(u) for u in board_moves])


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
        print(f"{desc} ({side_name(g, mover)}), move {board.fullmove_number}")
    else:
        print(f"game over: {desc}  [{result}]")


# ---------------------------------------------------------------- commands

def cmd_new(args):
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
    save_game(g)
    opp_side = "black" if args.side == "white" else "white"
    print(f"{g['id']}: you are {args.side}, {args.opponent} is {opp_side}")
    print_position(g, build_board(g))


def cmd_list(args):
    games = load_all()
    if not games:
        print("no games — crab-chess new <opponent>")
        return
    games.sort(key=lambda g: g.get("updated", ""), reverse=True)
    for g in games:
        board = build_board(g)
        _, desc, result = compute_state(g, board)
        white = side_name(g, "white")
        black = side_name(g, "black")
        tag = desc if result == "*" else f"{desc} [{result}]"
        print(f"{g['id']:<16} {white} v {black:<12} "
              f"{len(g['moves']):>3} plies  {tag}")


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
    if len(args.words) == 1:
        spec, text = None, args.words[0]
    elif len(args.words) == 2:
        spec, text = args.words
    else:
        raise CliError("usage: crab-chess move [game] <move>")
    g = resolve_game(spec)
    board = build_board(g)
    key, desc, _ = compute_state(g, board)
    if key != "active":
        raise CliError(f"{g['id']} is over ({desc}) — undo to reopen it, "
                       "or start a new game")
    move = parse_move(board, text)
    san = board.san(move)
    board.push(move)
    g["moves"].append(move.uci())
    save_game(g)
    print(f"{g['id']}: played {san}")
    print_position(g, board)


def cmd_undo(args):
    g = resolve_game(args.game)
    if not g["moves"] and not g["resigned_by"] and not g["draw_agreed"]:
        raise CliError(f"{g['id']}: nothing to undo")
    if g["resigned_by"] or g["draw_agreed"]:
        # First undo after a resignation or agreed draw reopens the game
        # without touching the moves.
        g["resigned_by"] = None
        g["draw_agreed"] = False
        undone = "the game-ending agreement"
    else:
        n = min(args.plies, len(g["moves"]))
        del g["moves"][-n:]
        undone = f"{n} ply" if n == 1 else f"{n} plies"
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
              f"move {board.fullmove_number}")
        print(f"state: {desc}")
        claims = []
        if board.can_claim_threefold_repetition():
            claims.append("threefold repetition")
        if board.can_claim_fifty_moves():
            claims.append("fifty-move rule")
        if claims:
            print(f"draw claimable: {', '.join(claims)}")
    else:
        print(f"state: {desc}  [{result}]")
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
    path = shutil.which("stockfish")
    if not path:
        raise CliError("stockfish is not on PATH — the engine opponent is "
                       "optional and currently unavailable; human play is "
                       "unaffected")
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
    save_game(g)
    lvl = f" (skill {level})" if level is not None else ""
    print(f"{g['id']}: engine{lvl} plays {san}")
    print_position(g, board)


# ---------------------------------------------------------------- entry

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="crab-chess",
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

    args = p.parse_args(argv)
    try:
        args.func(args)
    except CliError as e:
        print(f"crab-chess: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
