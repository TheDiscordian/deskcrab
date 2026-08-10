#!/usr/bin/env python3
"""chess_reflex: position memory for betty-chess.

Every move of every finished game, keyed by the FEN of the position it was
made from, with the game's result alongside — so a position she has met
before can be answered from memory in milliseconds instead of costing a
model reasoning turn. specs/chess-reflex.md is the contract.

The store is one SQLite file next to the game files (default
$DESKCRAB_CHESS_DIR/reflex.db, path overridable with
$DESKCRAB_CHESS_REFLEX_DB). Ingestion is idempotent per game and driven from
chess_cli.save_game, so every path that writes a game — the CLI, the engine,
the chessweb bridge — feeds the memory without knowing it exists; a game
reopened by undo is retracted the same way. Only finished games count: a
move's worth is how its games ended, and an unfinished game has not ended.
"""

import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import chess

SCHEMA = """
CREATE TABLE IF NOT EXISTS games (
    game_id    TEXT PRIMARY KEY,
    opponent   TEXT,
    my_side    TEXT,
    result     TEXT NOT NULL,     -- '1-0', '0-1', '1/2-1/2'
    my_outcome TEXT NOT NULL,     -- 'win', 'loss', 'draw' for the my_side player
    plies      INTEGER NOT NULL,
    ingested   TEXT NOT NULL,
    source     TEXT NOT NULL DEFAULT 'played'  -- 'played' or 'book' (theory)
);
CREATE TABLE IF NOT EXISTS moves (
    fen     TEXT NOT NULL,        -- the full FEN the move was made from
    fen_key TEXT NOT NULL,        -- its first four fields; what lookup keys on
    move    TEXT NOT NULL,        -- UCI
    colour  TEXT NOT NULL,        -- who made it: 'white' or 'black'
    ply     INTEGER NOT NULL,
    game_id TEXT NOT NULL REFERENCES games(game_id)
);
CREATE INDEX IF NOT EXISTS moves_by_key  ON moves(fen_key);
CREATE INDEX IF NOT EXISTS moves_by_game ON moves(game_id);
"""

# The auto-play gate: how many finished games must agree, and how well their
# results must have gone, before a remembered move is played without thinking.
MIN_GAMES = int(os.environ.get("DESKCRAB_REFLEX_MIN_GAMES", "2"))
MIN_SCORE = float(os.environ.get("DESKCRAB_REFLEX_MIN_SCORE", "0.55"))


def db_path() -> Path:
    override = os.environ.get("DESKCRAB_CHESS_REFLEX_DB")
    if override:
        return Path(override)
    chess_dir = Path(os.environ.get("DESKCRAB_CHESS_DIR",
                                    Path.home() / ".local/share/deskcrab/chess"))
    return chess_dir / "reflex.db"


def connect() -> sqlite3.Connection:
    path = db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    _migrate(conn)
    return conn


def _migrate(conn: sqlite3.Connection) -> None:
    """Stores written before the book existed have no `source`; everything in
    them was played, which is exactly what the column defaults to."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(games)")}
    if "source" not in cols:
        conn.execute("ALTER TABLE games ADD COLUMN source TEXT NOT NULL"
                     " DEFAULT 'played'")
        conn.commit()


def fen_key(fen: str) -> str:
    """Placement, side to move, castling, en passant — never the counters, so
    the same position reached at a different move number still hits."""
    return " ".join(fen.split()[:4])


# ---------------------------------------------------------------- ingestion

def game_result(g: dict, board: chess.Board) -> str:
    """The result column of chess_cli.compute_state, computed standalone so
    this module needs no import of the CLI it feeds. '*' means still active."""
    if g.get("resigned_by"):
        return "0-1" if g["resigned_by"] == "white" else "1-0"
    if g.get("draw_agreed"):
        return "1/2-1/2"
    if board.is_checkmate():
        return "0-1" if board.turn == chess.WHITE else "1-0"
    if (board.is_stalemate() or board.is_insufficient_material()
            or board.is_seventyfive_moves() or board.is_fivefold_repetition()):
        return "1/2-1/2"
    return "*"


def _retract(conn: sqlite3.Connection, game_id: str) -> None:
    conn.execute("DELETE FROM moves WHERE game_id = ?", (game_id,))
    conn.execute("DELETE FROM games WHERE game_id = ?", (game_id,))
    try:
        import chess_similar
        chess_similar.retract(conn, game_id)
    except Exception as e:  # the similarity layer is a passenger, never a brake
        print(f"chess-similar: retract of {game_id} skipped: {e}",
              file=sys.stderr)


def _ingest(conn: sqlite3.Connection, g: dict, board_final: chess.Board,
            result: str) -> None:
    _retract(conn, g["id"])  # idempotent: re-ingesting replaces, never doubles
    my_side = g.get("my_side")
    won = {"1-0": "white", "0-1": "black"}.get(result)
    outcome = "draw" if won is None else ("win" if won == my_side else "loss")
    conn.execute(
        "INSERT INTO games (game_id, opponent, my_side, result, my_outcome,"
        " plies, ingested, source) VALUES (?, ?, ?, ?, ?, ?, ?, 'played')",
        (g["id"], g.get("opponent"), my_side, result, outcome,
         len(g["moves"]),
         datetime.now(timezone.utc).isoformat(timespec="seconds")))
    board = chess.Board()
    for ply, uci in enumerate(g["moves"]):
        colour = "white" if board.turn == chess.WHITE else "black"
        conn.execute(
            "INSERT INTO moves (fen, fen_key, move, colour, ply, game_id)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (board.fen(), fen_key(board.fen()), uci, colour, ply, g["id"]))
        board.push(chess.Move.from_uci(uci))
    try:
        import chess_similar
        chess_similar.ingest(conn, g, result)
    except Exception as e:  # rule 12: the exact rows land even when these fail
        print(f"chess-similar: vectors for {g.get('id')} skipped: {e}",
              file=sys.stderr)


def sync_game(g: dict) -> None:
    """The choke point, called on every game save. A finished game is
    (re-)ingested; an active one is retracted, which is what makes an undo
    that reopens a game take its no-longer-true result back out. Never
    raises: memory must not be able to spoil a move that already happened."""
    try:
        board = chess.Board()
        for uci in g["moves"]:
            board.push(chess.Move.from_uci(uci))
        result = game_result(g, board)
        with connect() as conn:
            if result == "*":
                _retract(conn, g["id"])
            else:
                _ingest(conn, g, board, result)
    except Exception as e:
        print(f"chess-reflex: sync of {g.get('id')} failed: {e}",
              file=sys.stderr)


def backfill(games: list[dict]) -> tuple[int, int]:
    """Ingest every finished game in the list; (ingested, still_active)."""
    done = active = 0
    with connect() as conn:
        for g in games:
            board = chess.Board()
            for uci in g["moves"]:
                board.push(chess.Move.from_uci(uci))
            result = game_result(g, board)
            if result == "*":
                active += 1
            else:
                _ingest(conn, g, board, result)
                done += 1
    return done, active


# ---------------------------------------------------------------- lookup

def score(wins: int, draws: int, n: int) -> float:
    """Result-weighted, frequency-tempered: the observed points fraction,
    smoothed toward 0.5 by one phantom drawn game. A move played once and won
    scores 0.75; ten losses score 0.045; frequency moves the score away from
    the prior only as far as the results deserve."""
    return (wins + 0.5 * draws + 0.5) / (n + 1)


def lookup(fen: str) -> list[dict]:
    """Candidate moves for the side to move in `fen`, best first. Each is
    {move, n, wins, draws, losses, score, book}; wins are the mover's, so a
    move that led to losses ranks below one that won less often. `n` and the
    score count played games only — `book` is how many theory lines run
    through the move, and theory is never allowed to pass for experience."""
    key = fen_key(fen)
    with connect() as conn:
        rows = conn.execute(
            """SELECT m.move,
                      SUM(CASE WHEN g.source = 'played' THEN 1 ELSE 0 END),
                      SUM(CASE WHEN g.source = 'played'
                                AND ((m.colour = 'white' AND g.result = '1-0')
                                  OR (m.colour = 'black' AND g.result = '0-1'))
                          THEN 1 ELSE 0 END),
                      SUM(CASE WHEN g.source = 'played'
                                AND g.result = '1/2-1/2' THEN 1 ELSE 0 END),
                      SUM(CASE WHEN g.source = 'book' THEN 1 ELSE 0 END)
               FROM moves m JOIN games g ON g.game_id = m.game_id
               WHERE m.fen_key = ? GROUP BY m.move""", (key,)).fetchall()
    out = [{"move": move, "n": n, "wins": w, "draws": d, "losses": n - w - d,
            "score": score(w, d, n), "book": bk} for move, n, w, d, bk in rows]
    out.sort(key=lambda c: (-c["score"], -c["n"], -c["book"], c["move"]))
    return out


def best_move(fen: str, board: chess.Board | None = None,
              min_games: int = None, min_score: float = None) -> dict | None:
    """The move memory would play from `fen`, or None to fall through to
    normal play. The first candidate in rank order that clears the gate wins;
    a board, if given, also vetoes anything not legal on it (the key strips
    the counters, so this is belt on top of braces).

    Two ways through the gate: enough played games that ended well enough, or
    membership of the opening book. Experience outranks theory — a book move
    her own games have gone badly with is vetoed and thought about instead."""
    min_games = MIN_GAMES if min_games is None else min_games
    min_score = MIN_SCORE if min_score is None else min_score
    for cand in lookup(fen):
        enough = cand["n"] >= min_games
        played_ok = enough and cand["score"] >= min_score
        book_ok = cand["book"] > 0 and not (enough and not played_ok)
        if not (played_ok or book_ok):
            continue
        if board is not None:
            try:
                if chess.Move.from_uci(cand["move"]) not in board.legal_moves:
                    continue
            except chess.InvalidMoveError:
                continue
        return cand
    return None
