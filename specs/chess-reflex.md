# chess-reflex — position memory for betty-chess

## PURPOSE

She plays correspondence chess by being woken with a position and spending a full model reasoning
turn on it. Most positions are not new: openings repeat, and so do the traps opponents fall into.
This module (`lib/chess_reflex.py`) remembers every move of every *finished* game, keyed by the FEN
of the position the move was made from, together with how that game ended — so a position met
before can be answered from memory in milliseconds, and a wake (a whole reasoning turn) is only
spent on positions that are actually new. The chessweb bridge consults it before booking her wake;
`betty-chess reflex` exposes the same memory by hand.

Memory is not judgement: a move is only replayed when it has been played enough times and its
games ended well enough. A move that kept losing is remembered too — as a reason to think instead.

## CONTRACT

1. The store is one SQLite file, `$DESKCRAB_CHESS_DIR/reflex.db` by default, path overridable
   with `$DESKCRAB_CHESS_REFLEX_DB`. Two tables: `games` (game_id, opponent, my_side, result,
   my_outcome, plies, ingested) and `moves` (fen, fen_key, move, colour, ply, game_id) — the full
   FEN of the position each move was made from, the move in UCI, and the colour that made it.
   `fen_key` is the FEN's first four fields (placement, side, castling, en passant), never the
   halfmove or fullmove counters, so a position reached at a different move number still hits.
2. Only finished games are in the store. `chess_cli.save_game` is the one write path for game
   files, and it syncs reflex on every save: a game whose replayed state is over (checkmate,
   stalemate, draw rule, resignation, agreed draw) is ingested; an active one is retracted.
   Ingestion is idempotent per game_id — re-saving a finished game replaces its rows, never
   doubles them — and retraction is what makes an undo that reopens a finished game take its
   no-longer-true result back out of the memory.
3. A reflex failure never blocks chess. `sync_game` catches everything and warns on stderr; the
   game file is already saved before it runs. The bridge treats a lookup error as "unknown
   position" and books the wake as before.
4. `betty-chess reflex --backfill` ingests every finished game already in the games directory —
   the retroactive path for records written before this module existed, or written around
   `save_game` by another hand. Active games are counted and left out. Running it twice is
   harmless (rule 2's idempotence).
5. `betty-chess reflex <fen>` prints the candidate moves for the side to move, best first, each
   with its games count, W-D-L from the mover's perspective, and score; then a verdict line —
   `would play <san>` when the gate passes, `not confident enough` when known but thin, and a
   non-zero exit with `no memory of this position` when the position is unknown. The caller that
   cannot use the memory falls through to normal play.
6. Ranking weights frequency *and* results: score = (wins + draws/2 + 0.5) / (n + 1), wins and
   draws counted for the colour that made the move. The +0.5/+1 is one phantom drawn game: a
   move's score starts at 0.5 and moves away only as far as its results deserve, so a move played
   ten times and lost ten times scores 0.045 and sits below a move played once and won (0.75).
   Played-more never outranks lost-more.
7. The auto-play gate: a remembered move is played without thinking only when some candidate, in
   rank order, has been played in at least `$DESKCRAB_REFLEX_MIN_GAMES` finished games (default
   2) with a score of at least `$DESKCRAB_REFLEX_MIN_SCORE` (default 0.55), and is legal on the
   live board. Otherwise the answer is None and the caller thinks as it always did.
8. The wiring (chessweb.md rule 16): every path in the bridge that would book a wake for her move
   first asks `chess_reflex.best_move`. A hit is played straight into the store through the same
   write path as any move, broadcast to the browser, and logged as
   `reflex played <san> from memory` — and no wake is booked, which is the point. A miss books
   the wake exactly as before. A reflex move that *ends* the game still books the end-of-game
   wake, because she should hear how her game finished. `DESKCRAB_CHESS_REFLEX=0` turns the
   auto-play off; recording is unconditional.

## KNOWN LIMITS

- The memory is only as good as the games in it. Six losses to the same trap will stop the gate
  replaying the losing line (rule 6 down-weights it), but nothing in this module finds the
  refutation — that still costs a reasoning turn.
- `my_outcome` trusts `my_side`, which is her side in every game the bridge or her CLI writes;
  a game file written by another hand with `my_side` meaning someone else skews the stats table
  only — ranking (rule 6) counts by mover colour and does not care.
- Results are per-game, so early opening moves inherit the fate of the whole game. That is the
  design: an opening that keeps ending in losses *should* stop being played on reflex, even if
  ply 40 was where it actually went wrong.
