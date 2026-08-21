# chess-reflex — position memory for betty-chess

## PURPOSE

She plays correspondence chess by answering each position with a model call. Most positions are
not new: openings repeat, and so do the traps opponents fall into. This module
(`lib/chess_reflex.py`) remembers every move of every *finished* game, keyed by the FEN of the
position the move was made from, together with how that game ended — so a position met before can
be answered from memory in milliseconds, and a model call is only spent on positions that are
actually new. The chessweb bridge's resident mover (chessweb.md rule 16) consults it before any
model call; `betty-chess reflex` exposes the same memory by hand.

Memory is not judgement: a move is only replayed when it has been played enough times and its
games ended well enough. A move that kept losing is remembered too — as a reason to think instead.

## CONTRACT

1. The store is one SQLite file, `$DESKCRAB_CHESS_DIR/reflex.db` by default, path overridable
   with `$DESKCRAB_CHESS_REFLEX_DB`. Two tables: `games` (game_id, opponent, my_side, result,
   my_outcome, plies, ingested, source) and `moves` (fen, fen_key, move, colour, ply, game_id) — the full
   FEN of the position each move was made from, the move in UCI, and the colour that made it.
   `fen_key` is the FEN's first four fields (placement, side, castling, en passant), never the
   halfmove or fullmove counters, so a position reached at a different move number still hits.
2. Only finished games are in the store, plus opening theory marked as such. `source` is
   `'played'` for a real game and `'book'` for a seeded theory line; a book row is a position
   known to be sound, not a game anyone won, so its `result` is `'*'` and it is counted apart
   from played games everywhere (rules 5, 6, 9). Nothing but a seeder writes `'book'`, and the
   two never mix inside one game_id. `chess_cli.save_game` is the one write path for game
   files, and it syncs reflex on every save: a game whose replayed state is over (checkmate,
   stalemate, draw rule, resignation, agreed draw) is ingested; an active one is retracted.
   Ingestion is idempotent per game_id — re-saving a finished game replaces its rows, never
   doubles them — and retraction is what makes an undo that reopens a finished game take its
   no-longer-true result back out of the memory.
3. A reflex failure never blocks chess. `sync_game` catches everything and warns on stderr; the
   game file is already saved before it runs. The bridge treats a lookup error as "unknown
   position" and makes the model call as before.
4. `betty-chess reflex --backfill` ingests every finished game already in the games directory —
   the retroactive path for records written before this module existed, or written around
   `save_game` by another hand. Active games are counted and left out. Running it twice is
   harmless (rule 2's idempotence).
5. `betty-chess reflex [<fen>|<game>]` takes either a FEN or, like every other subcommand, a game
   id or opponent name (inferred when exactly one game is active) and reads that game's current
   position. A word that is neither is an error naming both failures. It prints the candidate moves for the side to move, best first, each
   with its played-games count, W-D-L from the mover's perspective, how many book lines contain
   it (`book N`, omitted at zero), and score; then a verdict line —
   `would play <san>` when the gate passes, `not confident enough` when known but thin, and a
   non-zero exit with `no memory of this position` when the position is unknown. The caller that
   cannot use the memory falls through to normal play.
6. Ranking weights frequency *and* results: score = (wins + draws/2 + 0.5) / (n + 1), over
   **played games only**, wins and draws counted for the colour that made the move. Book lines
   contribute nothing to the score — a move nobody has played yet sits at the 0.5 prior whether
   theory knows it or not — so a real loss is never diluted by however many book lines happen to
   run through the position. Among equal scores, the move in more book lines ranks first. The
   +0.5/+1 is one phantom drawn game: a
   move's score starts at 0.5 and moves away only as far as its results deserve, so a move played
   ten times and lost ten times scores 0.045 and sits below a move played once and won (0.75).
   Played-more never outranks lost-more.
7. The auto-play gate: a remembered move is played without thinking only when some candidate, in
   rank order, has been played in at least `$DESKCRAB_REFLEX_MIN_GAMES` finished games (default
   2) with a score of at least `$DESKCRAB_REFLEX_MIN_SCORE` (default 0.55), and is legal on the
   live board. A move in at least one book line clears the gate on theory alone — it needs no
   played games at all — *unless* her own games contradict it: `min_games` played games at a
   score below `min_score` veto the book, and she thinks instead. Experience always outranks
   theory, and theory only speaks where experience is silent. Otherwise the answer is None and
   the caller thinks as it always did.
8. The wiring (chessweb.md rule 16): every position the bridge's mover would answer with a model
   call first asks `chess_reflex.best_move`. A hit is played straight into the store through the
   same write path as any move, broadcast to the browser, and logged as
   `reflex played <san> from memory` — and no model call is made, which is the point. A miss
   goes to the model exactly as chessweb.md rule 16b says. A reflex move that *ends* the game
   still books the end-of-game wake, because she should hear how her game finished.
   `DESKCRAB_CHESS_REFLEX=0` turns the auto-play off; recording is unconditional.

9. `betty-chess reflex --seed-book` writes the opening book: mainline theory replayed with
   python-chess, one `source='book'` game per line, `game_id` prefixed `book-`, `result` `'*'`,
   `my_side` and `my_outcome` empty. Both colours' moves live in that one game, because a book
   row is a position and not a side's victory. Idempotent — seeding deletes the `book-` rows and
   rewrites them, and it never touches a played game.

## THE SIMILARITY LAYER

The exact layer only answers positions already met move for move. Most middlegames never repeat,
but they *rhyme* — the same structures, the same kind of king, the same imbalance. The second
layer (`lib/chess_similar.py`) remembers every played position as a hand-built feature vector, so
a position never seen exactly can still be answered with "here is what positions like this looked
like, what was played, and how those games ended". It informs; it never plays.

10. Alongside `games` and `moves`, reflex.db carries a `vectors` table: one row per ply of every
    finished **played** game — the full FEN, its `fen_key`, the feature vector (little-endian
    float32s, `struct`-packed as in memory.py), the move made from the position (UCI), the colour
    that made it (the side to move), the game's `result`, the mover's `outcome`
    (`win`/`draw`/`loss`), `ply`, and `game_id`. Book lines never enter it: a vector row answers
    "how did this go", and theory has no result.
11. The features come from python-chess arithmetic alone — **no engine, ever**; Stockfish and any
    other engine assistance are forbidden in this layer as everywhere in her chess. The module's
    `FEATURES` list is the order of record (64 names); every value is normalised into [0,1], and
    the paired features are computed from the mover's perspective — `us` is the side to move —
    so "similar" means "a similar situation for the player who must now choose". Groups:
    material and phase; pawn structure (isolated, doubled, passed, open and half-open files,
    advancement); king safety (shield, open files by the king, ring attackers, back rank);
    activity (mobility by piece type, centre, outposts, rooks on open files and the seventh
    rank, space, development); state (check, castling rights, which colour is to move).
    Extraction is deterministic: the same position yields the same bytes, across processes.
12. Ingestion and retraction ride the exact layer's own: `_ingest` writes the vector rows in the
    same transaction as the `moves` rows, retraction deletes by `game_id`, so rule 2's
    idempotence and the undo path cover both tables at once, and `reflex --backfill` fills both.
    A similarity failure is contained — the exact rows still land when the vector ones fail, and
    a store from before this layer grows the table on first touch.
13. `chess_similar.similar(fen, k)` is the one retrieval function; metric and ranking live behind
    it so the store can be swapped without touching a caller. Today it is brute force: euclidean
    distance over the whole table on the normalised vectors, reported as similarity
    `1 / (1 + distance)`, neighbours aggregated by `(fen_key, move)` with the mover's W-D-L
    across their games, nearest first. An exact-key row, when one exists, is simply the nearest
    neighbour (similarity 1.0), flagged `exact`. A row carrying no finished result — anything
    but `1-0`, `0-1` or `1/2-1/2` — is dropped at retrieval, before ranking or aggregation:
    rule 10 means no such row should exist (book lines never enter the vectors), but a stray
    one carries no information and must never reach a caller, least of all counted as a draw,
    which is what the ingest arithmetic would have called it.
14. The wiring (chessweb.md rule 16): the retrieval lives inside the mover's own prompt build
    (`lib/chess_mover.py`), never in a job builder — every driver of the mover (the bridge,
    self-play, whatever comes next) gets position memory structurally, so no caller can forget
    to pass it. It replaced the note design (`reason_note` handed in on the job), which starved
    her in practice: the live metrics for browser-018 and browser-022/023/024 show every
    middlegame `similar-context` stamp `empty` — the note's 0.75 floor silenced memory at the
    very plies those games collapsed at, and no similar-position help ever reached a middlegame
    move prompt. One section, rendered above the legal-move lists, reached only
    after the exact layer's auto-play gate has declined (rules 7 and 8 short-circuit first —
    the mover only ever sees positions memory would not answer alone):
    a. **There is no exact section.** An exact hit is the reflex's business, answered before
       any prompt is built; the move prompt never carries a block about this very position.
       Rows flagged `exact` are excluded from the rendered neighbours, and no header claims
       the position has been stood in before — the store holds moves by whichever colour,
       keyed on the position, so "she has stood here" was wrong about what is known. (Decided
       2026-08-21; the exact section briefly existed and printed alongside the similar one.)
    b. **The similar section.** `chess_similar.similar(fen)`, non-exact neighbours only,
       each with a finished result behind it (rule 13's retrieval filter),
       at most `$DESKCRAB_CHESS_PROMPT_SIM_K` (default 3) lines,
       each carrying the similarity, the move in SAN, the colour that played it, how those
       games ended and for whom, and the provenance (game id, ply). A precedent with more
       losses than wins is rendered as a named warning, never a suggestion. The k nearest are
       selected by rule 13's ranking, then ordered for rendering by outcome-weighted
       similarity — similarity × rule 6's score arithmetic — so a winning precedent outranks a
       nearer loss; nearness alone is never advice. There is **no similarity floor** in the
       prompt section: the floor is what kept memory silent through every collapse (measured
       above), retrieval is cheap enough to run at every ply with no opening gate (19–40 ms
       over the 3,238-row live store, measured 2026-08-21), and distance is priced by printing
       the similarity on the line rather than by silence.
    c. **A remembered win is not buried by the exchange count.** A memory-endorsed move — a
       similar hit with more wins than losses whose move is legal on this board — which
       `material_loss` flags is NOT dropped into the "play
       one only with a concrete reason" pile: it is listed on its own line carrying both facts,
       the exchange count against it and the record for it, because the record *is* a concrete
       reason and the model must weigh it rather than never see it.
    d. `DESKCRAB_CHESS_SIMILAR=0` switches the similar section off;
       `DESKCRAB_CHESS_MEMORY_PROMPT=0` likewise sends the prompt bare of memory (with one
       section the two switches now coincide; both stay, each honouring its name). Any retrieval
       failure is a bare prompt, never a lost move. The `similar-context` stamp (chessweb.md
       rule 17) is written by the mover as it builds the prompt, in its established shape, so
       its absence still proves a reflex hit short-circuited. `reason_note` — with its floor
       `$DESKCRAB_CHESS_SIMILAR_MIN` and its `$DESKCRAB_CHESS_SIMILAR_K` — remains what
       `betty-chess similar [<fen>|<game>] [-k N]` prints by hand, accepting a game id on the
       same terms as rule 5 and refusing loudly when the table is empty; the move path no
       longer uses it. Nothing in this layer is ever auto-played.

15. **The legal moves are printed, never counted by eye.** Every board the CLI prints for an
    active game carries a `legal (N): ...` line — the side to play's complete move list in SAN,
    sorted — and `betty-chess status` prints the same line. This is not a convenience: reading a
    drawn board and reasoning about which squares a king can reach is how a mate gets played into,
    and the library that draws the board already knows the answer exactly. A finished game prints
    no such line; its move list is empty and the state line says why.

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
- The similarity layer is only as wide as the store. With a handful of games every neighbour is
  thin — the prompt section still renders the nearest of them, with their honest similarity
  figures on the line, and those figures stay low until a few hundred games are in. That is
  expected, not broken. The features are hand-built heuristics, not evaluation: two positions
  can sit close in this space and demand different moves, which is why the layer may only ever
  inform the reasoning turn.
