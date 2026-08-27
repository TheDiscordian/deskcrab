#!/usr/bin/env python3
"""chess_effort: how hard to think about a move, decided before thinking.

Someone is waiting at the board. Most positions are quiet manoeuvring and
deserve a fast, cheap reasoning turn; a few are the whole game — a check, a
hanging piece, a pawn one square from queening — and skimping there loses in
one move what an evening of care built. This module is the pre-check that
tells the two apart: pure python-chess arithmetic over the board (NO engine,
ever — Stockfish and every other engine are forbidden here as everywhere in
her chess), returning an effort level and the list of reasons that fired, so
the wake that thinks about the move can be booked at the effort the position
actually deserves and the reasons can be read back later to tune the
thresholds.

It runs only when she must actually think: the exact-FEN reflex layer
(chess_reflex) short-circuits ahead of everything and plays from memory
without ever consulting this module. A classifier failure never blocks a
move — the caller books the wake without an effort override, exactly as
before this module existed.
"""

import os

import chess

# The two levels, each its own knob because the pair has been adjudicated
# more than once. Quiet ran at medium and alarmed at high from 2026-08-10's
# adjudication — the per-move minutes were the queue in front of the call,
# not the thinking inside it. On 2026-08-15 the user lowered the pair to
# low/medium, and the game-id-parity A/B that then interleaved the lowered
# pair with the old one was rejected by him outright (docs/history.md,
# 2026-08-26): one uniform pair for every game, no arms, no parity — and the
# pair he reaffirmed that day is the lowered low/medium; the cleanup removed
# the alternation, never the lowering. The knobs make the next adjudication
# a config line, not an edit (specs/chessweb.md rule 16b).
QUIET = os.environ.get("DESKCRAB_CHESS_EFFORT_QUIET", "low")
SHARP = os.environ.get("DESKCRAB_CHESS_EFFORT_SHARP", "medium")

# The clock picks the pair (specs/chessweb.md rule 16b, adopted 2026-08-27):
# a timed game reads its SPEED's pair, so a bullet game stops paying rapid
# thinking prices and a rapid game with increment can afford real thought.
# The defaults come from the 2026-08-27 self-play benchmark
# (docs/chess-bench-2026-08-27.md); each is overridable by its own knob, so
# the next adjudication is a config line here too. An untimed game — and any
# speed outside this table — keeps the uniform pair above, exactly as the
# 2026-08-26 adjudication left it.
SPEED_PAIRS = {
    "bullet": ("low", "medium"),
    "blitz": ("low", "medium"),
    "rapid": ("low", "medium"),
}


def pair_for(speed):
    """(quiet, sharp) for a game of `speed` — the per-speed knobs first,
    then the benchmark-chosen defaults; (QUIET, SHARP) for no speed."""
    if not speed or speed not in SPEED_PAIRS:
        return (QUIET, SHARP)
    dq, ds = SPEED_PAIRS[speed]
    return (os.environ.get("DESKCRAB_CHESS_EFFORT_%s_QUIET" % speed.upper(),
                           dq),
            os.environ.get("DESKCRAB_CHESS_EFFORT_%s_SHARP" % speed.upper(),
                           ds))

PIECE_VALUE = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3,
               chess.ROOK: 5, chess.QUEEN: 9}
MINOR_VALUE = 3

# At or below this many legal moves the position is treated as forced — a
# narrow tree is where one careless reply is the game.
FORCED_MAX = int(os.environ.get("DESKCRAB_CHESS_EFFORT_FORCED", "8"))

# A capture is only an alarm when it is worth a rook or more. Any minor-piece
# capture qualifying meant near enough every middlegame position escalated.
CAPTURE_MIN = int(os.environ.get("DESKCRAB_CHESS_EFFORT_CAPTURE", "5"))

# The novelty gate. A position is "genuinely new ground" only when the vector
# store is big enough to have an opinion (fewer rows than NOVEL_ROWS and every
# position would look novel, making every wake expensive — the opposite of the
# point) and still nothing sits at or above NOVEL_MIN similarity.
NOVEL_ROWS = int(os.environ.get("DESKCRAB_CHESS_EFFORT_NOVEL_ROWS", "500"))
NOVEL_MIN = float(os.environ.get("DESKCRAB_CHESS_EFFORT_NOVEL_MIN", "0.75"))


def _value(piece_type):
    return PIECE_VALUE.get(piece_type, 0)


def _capture_value(board, move):
    """What a capture wins, before recapture: the victim's value."""
    if not board.is_capture(move):
        return 0
    victim = board.piece_type_at(move.to_square)
    return _value(victim) if victim else PIECE_VALUE[chess.PAWN]  # en passant


def _their_view(board):
    """The position with the move handed to the opponent, for asking what
    THEY could do to us. Only sound when we are not in check (a null move out
    of check leaves a king en prise and the move generator answering for an
    illegal position) — the caller has already fired on the check by then."""
    flipped = board.copy(stack=False)
    flipped.push(chess.Move.null())
    return flipped


def _en_prise(board, us):
    """Squares of our pieces (never pawns, never the king) that a simple
    SEE-ish count says are loose: attacked and undefended, attacked by
    something cheaper, or outnumbered at equal value. Pins and batteries are
    beyond a pre-check — this decides how hard to think, not what to play."""
    them = not us
    loose = []
    for sq in chess.SquareSet(board.occupied_co[us]):
        pt = board.piece_type_at(sq)
        if pt in (chess.KING, chess.PAWN):
            continue
        attackers = board.attackers(them, sq)
        if not attackers:
            continue
        defenders = board.attackers(us, sq)
        # A king "attacker" is only real against an undefended piece, so it
        # must never register as the cheap attacker in the value test.
        cheapest = min((_value(board.piece_type_at(a)) or 99
                        for a in attackers))
        if (not defenders or cheapest < _value(pt)
                or (len(attackers) > len(defenders)
                    and cheapest <= _value(pt))):
            loose.append(chess.square_name(sq))
    return loose


def _king_danger(board, us):
    """The two cheap king-safety alarms, for the side to move only — the
    opponent's king is their problem. Both are gated so a quiet opening does
    not trip them: the shield is only judged for a king that has left the
    centre files of its back two ranks (an uncastled king behind its own
    unmoved pawns is not 'broken'), and neither alarm sounds once the
    opponent has no rook or queen left to exploit the gap — a bare-kings
    endgame is not a king attack."""
    reasons = []
    king = board.king(us)
    if king is None:
        return reasons
    them = not us
    kf, kr = chess.square_file(king), chess.square_rank(king)
    near = [f for f in (kf - 1, kf, kf + 1) if 0 <= f <= 7]
    my_pawn_files = {chess.square_file(s)
                     for s in board.pieces(chess.PAWN, us)}

    they_have_heavies = bool(board.pieces(chess.ROOK, them)
                             | board.pieces(chess.QUEEN, them))
    if not they_have_heavies:
        return reasons
    if any(f not in my_pawn_files for f in near):
        reasons.append("king-open-file")

    back = 0 if us == chess.WHITE else 7
    home_ranks = (back, back + 1) if us == chess.WHITE else (back, back - 1)
    castled_ish = kr in home_ranks and kf not in (3, 4)
    if castled_ish:
        forward = (1, 2) if us == chess.WHITE else (-1, -2)
        pawns = board.pieces(chess.PAWN, us)
        bare = 0
        for f in near:
            if not any(0 <= kr + d <= 7 and chess.square(f, kr + d) in pawns
                       for d in forward):
                bare += 1
        if bare >= 2:
            reasons.append("shield-broken")
    return reasons


def classify(board: chess.Board, novel=None,
             pair=None) -> tuple[str, list[str]]:
    """The effort a position deserves: (level, reasons-that-fired). QUIET
    with no reasons is the quiet default; any reason at all means SHARP — a
    cheap alarm that rings falsely now and then costs one deliberate turn,
    where an alarm that stays quiet falsely can cost the game. Pure
    arithmetic on the board; `novel` is the store's verdict (novelty()),
    passed in so this function stays free of I/O and deterministic under
    test. `pair` is an optional (quiet, sharp) override — pair_for(speed)
    for a timed game, a benchmark side's own pair — and its absence is the
    module pair, exactly as before it existed."""
    us = board.turn
    quiet_level, sharp_level = pair or (QUIET, SHARP)
    reasons = []

    if board.is_check():
        reasons.append("in-check")

    my_moves = list(board.legal_moves)

    if not board.is_check():
        # A check merely EXISTING is not an alarm — in a normal middlegame
        # some spite check is nearly always available, and firing on it made
        # every move expensive (browser-003, every ply of it, 2026-08-10).
        # Only a check that also wins material, or one in a position narrow
        # enough to be forcing, is worth the deliberate turn.
        def _sharp(b):
            narrow = len(list(b.legal_moves)) <= FORCED_MAX
            return any(b.gives_check(m)
                       and (narrow or _capture_value(b, m) >= MINOR_VALUE)
                       for m in b.legal_moves)

        if _sharp(board) or _sharp(_their_view(board)):
            reasons.append("check-available")

    loose = _en_prise(board, us)
    if loose:
        reasons.append("en-prise:" + ",".join(loose))

    big = max((_capture_value(board, m) for m in my_moves), default=0)
    if big < CAPTURE_MIN and not board.is_check():
        flipped = _their_view(board)
        big = max((_capture_value(flipped, m) for m in flipped.legal_moves),
                  default=0)
    if big >= CAPTURE_MIN:
        reasons.append(f"capture-worth:{big}")

    if (board.pieces(chess.PAWN, chess.WHITE) & chess.BB_RANK_7) or \
            (board.pieces(chess.PAWN, chess.BLACK) & chess.BB_RANK_2):
        reasons.append("pawn-on-7th")

    reasons.extend(_king_danger(board, us))

    if len(my_moves) <= FORCED_MAX:
        reasons.append(f"forced:{len(my_moves)}")

    if novel:
        reasons.append("novel")

    return (sharp_level if reasons else quiet_level), reasons


def novelty(fen: str, min_rows: int = None, min_sim: float = None):
    """The similarity store's verdict on `fen`: True when the store is big
    enough to judge and still has nothing near, False when a neighbour is
    close, None when it cannot say (no store, a thin store, any failure).
    None and False read the same to classify() — only a confident 'this is
    new ground' escalates."""
    min_rows = NOVEL_ROWS if min_rows is None else min_rows
    min_sim = NOVEL_MIN if min_sim is None else min_sim
    try:
        import chess_reflex
        import chess_similar
        with chess_reflex.connect() as conn:
            chess_similar.ensure(conn)
            rows = conn.execute("SELECT COUNT(*) FROM vectors").fetchone()[0]
        if rows < min_rows:
            return None
        hits = chess_similar.similar(fen, k=1)
        return not hits or hits[0]["similarity"] < min_sim
    except Exception:
        return None


if __name__ == "__main__":
    # A bare debugging entry: FEN on argv, the verdict and its reasons out.
    import sys
    fen = " ".join(sys.argv[1:]) or chess.STARTING_FEN
    b = chess.Board(fen)
    level, why = classify(b, novel=novelty(b.fen()))
    print(f"{level}  {' '.join(why) if why else '(quiet)'}")
