#!/usr/bin/env python3
"""chess_similar: the similarity layer of betty-chess's position memory.

The exact layer (chess_reflex) only answers positions met move for move.
Middlegames rarely repeat, but they rhyme — the same pawn structures, the same
kind of king, the same imbalance — so every played position is also stored as
a hand-built feature vector, and a position never seen exactly can still be
answered with "here is what positions like this looked like, what was played,
and how those games ended". Context only: nothing here ever plays a move.
specs/chess-reflex.md rules 10-14 are the contract.

The features are python-chess arithmetic and nothing else. No engine — not
Stockfish, not anything — is consulted in this layer or anywhere in her chess.
"""

import os
import struct
import sys

import chess

import chess_reflex

SCHEMA = """
CREATE TABLE IF NOT EXISTS vectors (
    fen     TEXT NOT NULL,        -- the full FEN the move was made from
    fen_key TEXT NOT NULL,        -- its first four fields, as in moves
    vec     BLOB NOT NULL,        -- len(FEATURES) little-endian float32s
    move    TEXT NOT NULL,        -- UCI, played from this position
    colour  TEXT NOT NULL,        -- the mover == the side to move here
    result  TEXT NOT NULL,        -- how the whole game ended
    outcome TEXT NOT NULL,        -- 'win', 'draw', 'loss' for the mover
    ply     INTEGER NOT NULL,
    game_id TEXT NOT NULL REFERENCES games(game_id)
);
CREATE INDEX IF NOT EXISTS vectors_by_game ON vectors(game_id);
CREATE INDEX IF NOT EXISTS vectors_by_key  ON vectors(fen_key);
"""

# How many neighbours the wake note carries, and how near a neighbour must be
# before it is worth a reasoning turn's attention. Distances here are euclidean
# over the [0,1] features, reported as 1/(1+d) — see similar().
NOTE_K = int(os.environ.get("DESKCRAB_CHESS_SIMILAR_K", "3"))
MIN_SIM = float(os.environ.get("DESKCRAB_CHESS_SIMILAR_MIN", "0.75"))

# The order of record. Paired features are from the mover's perspective: `us`
# is the side to move in the position, `them` the opponent. Every value is
# normalised into [0,1]; the divisor is the feature's practical ceiling, and
# anything a promotion pushes past it is clamped rather than allowed to
# stretch every other position's distances.
FEATURES = [
    "us_pawns", "us_knights", "us_bishops", "us_rooks", "us_queens",
    "them_pawns", "them_knights", "them_bishops", "them_rooks", "them_queens",
    "us_bishop_pair", "them_bishop_pair",
    "material_balance", "phase",
    "us_isolated", "them_isolated", "us_doubled", "them_doubled",
    "us_passed", "them_passed",
    "open_files", "us_half_open", "them_half_open",
    "us_pawn_advance", "them_pawn_advance",
    "us_passed_advance", "them_passed_advance",
    "us_king_shield", "them_king_shield",
    "us_king_open_files", "them_king_open_files",
    "us_king_ring_attackers", "them_king_ring_attackers",
    "us_king_back_rank", "them_king_back_rank",
    "us_knight_mobility", "them_knight_mobility",
    "us_bishop_mobility", "them_bishop_mobility",
    "us_rook_mobility", "them_rook_mobility",
    "us_queen_mobility", "them_queen_mobility",
    "us_centre_attacks", "them_centre_attacks",
    "us_centre_pawns", "them_centre_pawns",
    "us_outposts", "them_outposts",
    "us_rooks_open", "them_rooks_open",
    "us_rooks_seventh", "them_rooks_seventh",
    "us_space", "them_space", "us_developed", "them_developed",
    "total_pawns",
    "check", "us_castle_k", "us_castle_q", "them_castle_k", "them_castle_q",
    "stm_white",
]

PIECE_VALUE = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3,
               chess.ROOK: 5, chess.QUEEN: 9}
CENTRE = (chess.D4, chess.E4, chess.D5, chess.E5)
CENTRE_BB = sum(chess.BB_SQUARES[s] for s in CENTRE)
MOBILITY_CAP = {chess.KNIGHT: 16, chess.BISHOP: 26,
                chess.ROOK: 28, chess.QUEEN: 27}


def _clamp(x):
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else float(x))


def _progress(colour, square):
    """How far a pawn on `square` has come, 0.0 on its home rank, 1.0 on the
    rank before promotion."""
    rank = chess.square_rank(square)
    steps = (rank - 1) if colour == chess.WHITE else (6 - rank)
    return _clamp(steps / 5)


def _ahead(colour, rank_a, rank_b):
    """Is a pawn on rank_b strictly ahead of rank_a, from `colour`'s view?"""
    return rank_b > rank_a if colour == chess.WHITE else rank_b < rank_a


def _side(board, us):
    """The one-sided features, as a dict keyed by the bare names above."""
    them = not us
    f = {}
    pawns = board.pieces(chess.PAWN, us)
    their_pawns = board.pieces(chess.PAWN, them)
    files = [chess.square_file(s) for s in pawns]
    their_files = {chess.square_file(s) for s in their_pawns}

    for name, pt, cap in (("pawns", chess.PAWN, 8), ("knights", chess.KNIGHT, 2),
                          ("bishops", chess.BISHOP, 2), ("rooks", chess.ROOK, 2),
                          ("queens", chess.QUEEN, 1)):
        f[name] = _clamp(len(board.pieces(pt, us)) / cap)
    f["bishop_pair"] = 1.0 if len(board.pieces(chess.BISHOP, us)) >= 2 else 0.0

    isolated = doubled = passed = 0
    passed_advance = 0.0
    for sq in pawns:
        file = chess.square_file(sq)
        rank = chess.square_rank(sq)
        if not any(abs(other - file) == 1 for other in files):
            isolated += 1
        if not any(abs(chess.square_file(p) - file) <= 1
                   and _ahead(us, rank, chess.square_rank(p))
                   for p in their_pawns):
            passed += 1
            passed_advance = max(passed_advance, _progress(us, sq))
    for file in set(files):
        doubled += files.count(file) - 1
    f["isolated"] = isolated / 8
    f["doubled"] = doubled / 8
    f["passed"] = passed / 8
    f["half_open"] = sum(1 for file in range(8)
                         if file not in files and file in their_files) / 8
    f["pawn_advance"] = (sum(_progress(us, s) for s in pawns) / len(pawns)
                         if pawns else 0.0)
    f["passed_advance"] = passed_advance

    king = board.king(us)
    if king is None:
        f["king_shield"] = f["king_open_files"] = 0.0
        f["king_ring_attackers"] = f["king_back_rank"] = 0.0
    else:
        kf, kr = chess.square_file(king), chess.square_rank(king)
        near = [file for file in (kf - 1, kf, kf + 1) if 0 <= file <= 7]
        forward = (1, 2) if us == chess.WHITE else (-1, -2)
        shield = sum(1 for file in near for d in forward
                     if 0 <= kr + d <= 7
                     and chess.square(file, kr + d) in pawns)
        f["king_shield"] = _clamp(shield / 6)
        f["king_open_files"] = sum(1 for file in near
                                   if file not in files) / len(near)
        ring = chess.SquareSet(chess.BB_KING_ATTACKS[king])
        attackers = set()
        for sq in ring:
            for a in board.attackers(them, sq):
                if board.piece_type_at(a) not in (chess.PAWN, chess.KING):
                    attackers.add(a)
        f["king_ring_attackers"] = _clamp(len(attackers) / 5)
        back = 0 if us == chess.WHITE else 7
        f["king_back_rank"] = 1.0 if kr == back else 0.0

    own = board.occupied_co[us]
    attacked = chess.SquareSet(0)
    for name, pt in (("knight", chess.KNIGHT), ("bishop", chess.BISHOP),
                     ("rook", chess.ROOK), ("queen", chess.QUEEN)):
        reach = 0
        for sq in board.pieces(pt, us):
            reach += len(board.attacks(sq) & ~chess.SquareSet(own))
        f[f"{name}_mobility"] = _clamp(reach / MOBILITY_CAP[pt])
    for sq in chess.SquareSet(board.occupied_co[us]):
        attacked |= board.attacks(sq)

    f["centre_attacks"] = _clamp(
        sum(len(board.attackers(us, c)) for c in CENTRE) / 8)
    f["centre_pawns"] = _clamp(len(pawns & chess.SquareSet(CENTRE_BB)) / 2)

    enemy_half = (chess.BB_RANK_5 | chess.BB_RANK_6 | chess.BB_RANK_7
                  | chess.BB_RANK_8) if us == chess.WHITE else (
                  chess.BB_RANK_1 | chess.BB_RANK_2 | chess.BB_RANK_3
                  | chess.BB_RANK_4)
    f["space"] = len(attacked & chess.SquareSet(enemy_half)) / 32

    outposts = 0
    for sq in board.pieces(chess.KNIGHT, us):
        if not chess.BB_SQUARES[sq] & enemy_half:
            continue
        file, rank = chess.square_file(sq), chess.square_rank(sq)
        held = any(board.piece_type_at(a) == chess.PAWN
                   for a in board.attackers(us, sq))
        # Evictable: an enemy pawn on an adjacent file that is still behind
        # enough to advance and hit this square one day.
        evictable = any(abs(chess.square_file(p) - file) == 1
                        and _ahead(us, rank, chess.square_rank(p))
                        for p in their_pawns)
        if held and not evictable:
            outposts += 1
    f["outposts"] = _clamp(outposts / 2)

    open_rooks = seventh = 0
    seventh_rank = 6 if us == chess.WHITE else 1
    for sq in board.pieces(chess.ROOK, us):
        file = chess.square_file(sq)
        if file not in files and file not in their_files:
            open_rooks += 1
        if chess.square_rank(sq) == seventh_rank:
            seventh += 1
    f["rooks_open"] = _clamp(open_rooks / 2)
    f["rooks_seventh"] = _clamp(seventh / 2)

    minors = (board.pieces(chess.KNIGHT, us) | board.pieces(chess.BISHOP, us))
    home = chess.BB_RANK_1 if us == chess.WHITE else chess.BB_RANK_8
    f["developed"] = _clamp(
        len(minors & ~chess.SquareSet(home)) / 4)

    f["castle_k"] = 1.0 if board.has_kingside_castling_rights(us) else 0.0
    f["castle_q"] = 1.0 if board.has_queenside_castling_rights(us) else 0.0
    return f


def extract(board: chess.Board) -> list[float]:
    """The feature vector of `board`, in FEATURES order, every value in
    [0,1]. Pure arithmetic on the position: deterministic across calls,
    boards, and processes."""
    us, them = board.turn, not board.turn
    ours, theirs = _side(board, us), _side(board, them)

    def material(side):
        return sum(len(board.pieces(pt, side)) * v
                   for pt, v in PIECE_VALUE.items())

    piece_material = sum(len(board.pieces(pt, side)) * PIECE_VALUE[pt]
                         for side in (chess.WHITE, chess.BLACK)
                         for pt in (chess.KNIGHT, chess.BISHOP,
                                    chess.ROOK, chess.QUEEN))
    all_pawn_files = ({chess.square_file(s)
                       for s in board.pieces(chess.PAWN, chess.WHITE)}
                      | {chess.square_file(s)
                         for s in board.pieces(chess.PAWN, chess.BLACK)})
    shared = {
        "material_balance": _clamp(
            0.5 + (material(us) - material(them)) / 20),
        "phase": _clamp(piece_material / 62),
        "open_files": (8 - len(all_pawn_files)) / 8,
        "total_pawns": (len(board.pieces(chess.PAWN, chess.WHITE))
                        + len(board.pieces(chess.PAWN, chess.BLACK))) / 16,
        "check": 1.0 if board.is_check() else 0.0,
        "stm_white": 1.0 if us == chess.WHITE else 0.0,
    }

    vec = []
    for name in FEATURES:
        if name in shared:
            vec.append(shared[name])
        elif name.startswith("us_"):
            vec.append(ours[name[3:]])
        else:
            vec.append(theirs[name[5:]])
    return vec


def pack(vec):
    return struct.pack(f"<{len(vec)}f", *vec)


def unpack(blob):
    return list(struct.unpack(f"<{len(blob) // 4}f", blob))


# ---------------------------------------------------------------- ingestion

def ensure(conn) -> None:
    conn.executescript(SCHEMA)


def retract(conn, game_id: str) -> None:
    ensure(conn)
    conn.execute("DELETE FROM vectors WHERE game_id = ?", (game_id,))


def ingest(conn, g: dict, result: str) -> None:
    """Vector rows for a finished played game, in the caller's transaction.
    chess_reflex._ingest has already retracted the game's old rows."""
    ensure(conn)
    won = {"1-0": "white", "0-1": "black"}.get(result)
    board = chess.Board()
    for ply, uci in enumerate(g["moves"]):
        colour = "white" if board.turn == chess.WHITE else "black"
        outcome = "draw" if won is None else (
            "win" if won == colour else "loss")
        fen = board.fen()
        conn.execute(
            "INSERT INTO vectors (fen, fen_key, vec, move, colour, result,"
            " outcome, ply, game_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (fen, chess_reflex.fen_key(fen), pack(extract(board)), uci,
             colour, result, outcome, ply, g["id"]))
        board.push(chess.Move.from_uci(uci))


# ---------------------------------------------------------------- retrieval

def _rank(query_vec, rows):
    """Distance and order live here so the metric can be swapped without
    touching a caller: euclidean over the normalised features, reported as
    similarity 1/(1+d)."""
    ranked = []
    for row in rows:
        vec = unpack(row[2])
        if len(vec) != len(query_vec):
            continue  # written by a different FEATURES era; ignore, re-backfill heals
        d = sum((a - b) ** 2 for a, b in zip(query_vec, vec)) ** 0.5
        ranked.append((1.0 / (1.0 + d), row))
    ranked.sort(key=lambda t: -t[0])
    return ranked


def similar(fen: str, k: int = 6) -> list[dict]:
    """The k stored positions nearest to `fen`, nearest first, aggregated by
    (fen_key, move): each is {fen, move, san, colour, ply, game_id, n, wins,
    draws, losses, similarity, exact}. Brute force over the whole table —
    fine at this scale, and the ranking sits behind _rank for the day it
    is not."""
    board = chess.Board(fen)
    query_vec = extract(board)
    query_key = chess_reflex.fen_key(board.fen())
    with chess_reflex.connect() as conn:
        ensure(conn)
        rows = conn.execute(
            "SELECT fen, fen_key, vec, move, colour, outcome, ply, game_id"
            " FROM vectors").fetchall()

    out, seen = [], {}
    for sim, (r_fen, r_key, _vec, move, colour, outcome, ply, gid) in \
            _rank(query_vec, rows):
        group = seen.get((r_key, move))
        if group is None:
            if len(seen) >= k:
                continue
            try:
                san = chess.Board(r_fen).san(chess.Move.from_uci(move))
            except (ValueError, AssertionError):
                san = move
            group = {"fen": r_fen, "move": move, "san": san, "colour": colour,
                     "ply": ply, "game_id": gid, "n": 0, "wins": 0,
                     "draws": 0, "losses": 0, "similarity": sim,
                     "exact": r_key == query_key}
            seen[(r_key, move)] = group
            out.append(group)
        group["n"] += 1
        group[{"win": "wins", "draw": "draws", "loss": "losses"}[outcome]] += 1
    return out


def reason_note(board: chess.Board, k: int = None, min_sim: float = None) -> str:
    """The similarity context appended to a move wake's reason when the exact
    layer had nothing — see specs/chess-reflex.md rule 14. Empty string when
    the store is empty or every neighbour is too far to be worth words."""
    k = NOTE_K if k is None else k
    min_sim = MIN_SIM if min_sim is None else min_sim
    hits = [h for h in similar(board.fen(), k) if h["similarity"] >= min_sim]
    if not hits:
        return ""
    ended = {"wins": "won", "draws": "drew", "losses": "lost"}
    parts = []
    for h in hits:
        record = ", ".join(f"{ended[key]} {h[key]}" for key
                           in ("wins", "draws", "losses") if h[key])
        parts.append(f"{h['san']} as {h['colour']} ({record}; similarity "
                     f"{h['similarity']:.2f}, {h['game_id']} ply {h['ply']})")
    return (" Exact memory has nothing here, but the nearest positions from "
            f"her finished games saw: {'; '.join(parts)}. Similar is not "
            "same — this is context for your thinking, never a move to copy "
            "without checking it against the board in front of you.")


if __name__ == "__main__":
    # A bare debugging entry: FEN on argv, features or neighbours on stdout.
    fen = " ".join(sys.argv[1:]) or chess.STARTING_FEN
    b = chess.Board(fen)
    for name, value in zip(FEATURES, extract(b)):
        print(f"{name:<24} {value:.3f}")
