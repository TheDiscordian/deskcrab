#!/usr/bin/env python3
"""chess_book: mainline opening theory, seeded into the reflex store.

The reflex memory only knows positions she has already played, so her first
game starts from nothing and every opening move costs a whole reasoning turn.
This module fills that gap with known theory — twenty-odd mainlines, replayed
with python-chess so the FENs are the store's own, written as `source='book'`
games (specs/chess-reflex.md rule 9).

Book rows are not games anyone won. They carry no result, they never enter a
move's score, and her own games override them: theory speaks only where her
experience is silent. Seeding is idempotent and never touches a played game.
"""

import sqlite3
from datetime import datetime, timezone

import chess

import chess_reflex

# Mainline theory, ~12-14 ply each: enough to leave the opening, not so deep
# that it pretends to know the middlegame. Both colours in one line.
LINES = {
    "italian-giuoco":       "e4 e5 Nf3 Nc6 Bc4 Bc5 c3 Nf6 d3 d6 O-O O-O",
    "italian-two-knights":  "e4 e5 Nf3 Nc6 Bc4 Nf6 d3 Be7 O-O O-O Re1 d6",
    "ruy-closed":           "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7 Re1 b5 Bb3 d6",
    "ruy-berlin":           "e4 e5 Nf3 Nc6 Bb5 Nf6 O-O Nxe4 d4 Nd6 Bxc6 dxc6",
    "scotch-mieses":        "e4 e5 Nf3 Nc6 d4 exd4 Nxd4 Nf6 Nxc6 bxc6 e5 Qe7 Qe2 Nd5",
    "scotch-classical":     "e4 e5 Nf3 Nc6 d4 exd4 Nxd4 Bc5 Be3 Qf6 c3 Nge7",
    "qgd-orthodox":         "d4 d5 c4 e6 Nc3 Nf6 Bg5 Be7 e3 O-O Nf3 Nbd7",
    "qga-main":             "d4 d5 c4 dxc4 Nf3 Nf6 e3 e6 Bxc4 c5 O-O a6",
    "slav-main":            "d4 d5 c4 c6 Nf3 Nf6 Nc3 dxc4 a4 Bf5 e3 e6",
    "london-main":          "d4 d5 Bf4 Nf6 e3 c5 c3 Nc6 Nd2 e6 Ngf3 Bd6",
    "sicilian-najdorf":     "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3 e5 Nb3 Be6",
    "sicilian-dragon":      "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3 Bg7 f3 O-O",
    "sicilian-sveshnikov":  "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 Nf6 Nc3 e5 Ndb5 d6",
    "french-classical":     "e4 e6 d4 d5 Nc3 Nf6 Bg5 Be7 e5 Nfd7 Bxe7 Qxe7",
    "french-winawer":       "e4 e6 d4 d5 Nc3 Bb4 e5 c5 a3 Bxc3+ bxc3 Ne7",
    "caro-classical":       "e4 c6 d4 d5 Nc3 dxe4 Nxe4 Bf5 Ng3 Bg6 h4 h6",
    "caro-advance":         "e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 c5 O-O Nc6",
    "kid-classical":        "d4 Nf6 c4 g6 Nc3 Bg7 e4 d6 Nf3 O-O Be2 e5",
    "nimzo-rubinstein":     "d4 Nf6 c4 e6 Nc3 Bb4 e3 O-O Bd3 d5 Nf3 c5",
    "english-reversed":     "c4 e5 Nc3 Nf6 Nf3 Nc6 g3 d5 cxd5 Nxd5 Bg2 Nb6",
    "english-symmetrical":  "c4 c5 Nc3 Nc6 g3 g6 Bg2 Bg7 Nf3 Nf6 O-O O-O",
}

BOOK_PREFIX = "book-"


def replay(san_line: str) -> list[tuple[int, str, str, str]]:
    """(ply, fen, uci, colour) for each move, legality-checked as it goes —
    a typo in the table above raises here rather than poisoning the store."""
    board = chess.Board()
    rows = []
    for ply, san in enumerate(san_line.split()):
        move = board.parse_san(san)
        colour = "white" if board.turn == chess.WHITE else "black"
        rows.append((ply, board.fen(), move.uci(), colour))
        board.push(move)
    return rows


def _counts(conn: sqlite3.Connection) -> tuple[int, int]:
    return tuple(conn.execute(
        "SELECT (SELECT COUNT(*) FROM moves),"
        " (SELECT COUNT(DISTINCT fen_key) FROM moves)").fetchone())


def seed(lines: dict[str, str] = None) -> dict:
    """Rewrite the book. Returns {lines, moves, positions_before/after}."""
    lines = LINES if lines is None else lines
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    replayed = {name: replay(san) for name, san in lines.items()}  # before any write
    with chess_reflex.connect() as conn:
        before = _counts(conn)
        # Cleared by source, not by name: a played game that happened to be
        # called book-something must survive a reseed.
        conn.execute("DELETE FROM moves WHERE game_id IN"
                     " (SELECT game_id FROM games WHERE source = 'book')")
        conn.execute("DELETE FROM games WHERE source = 'book'")
        for name, rows in replayed.items():
            gid = BOOK_PREFIX + name
            conn.execute(
                "INSERT INTO games (game_id, opponent, my_side, result,"
                " my_outcome, plies, ingested, source)"
                " VALUES (?, NULL, NULL, '*', '', ?, ?, 'book')",
                (gid, len(rows), now))
            conn.executemany(
                "INSERT INTO moves (fen, fen_key, move, colour, ply, game_id)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                [(fen, chess_reflex.fen_key(fen), uci, colour, ply, gid)
                 for ply, fen, uci, colour in rows])
        after = _counts(conn)
    return {"lines": len(replayed),
            "moves": sum(len(r) for r in replayed.values()),
            "positions_before": before[1], "positions_after": after[1],
            "rows_before": before[0], "rows_after": after[0]}
