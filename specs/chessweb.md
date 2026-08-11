# chessweb — the browser board onto a betty-chess game

## PURPOSE

betty-chess holds a correspondence game on disk, and she plays it by running `betty-chess move`.
This module gives the *other* player a real board: a browser page where the user drags pieces,
while she keeps playing exactly as before. The bridge is a SpeedyChess-protocol server
(`lib/chessweb.py`, run through `lib/betty-chessweb`): it serves the stock SpeedyChess web client
over HTTP and speaks its wire protocol over WebSocket upgrades on the same port. It owns no game
state of its own — the betty-chess game file is the one record. The user's moves are validated and
appended there; moves appended there by any other hand (hers, via `betty-chess move`) are mirrored
into the browser; and every recorded user move is answered by the bridge's resident mover
(`lib/chess_mover.py`, rule 16): reflex memory first, one minimal model call otherwise, her reply
on the board in seconds. Her move never rides the wake queue — somebody is sitting at the board
waiting for it, and the queue serialises behind whatever conversation is running.

The page it serves is the shipped client (`lib/chessweb_client/` — see THE SHIPPED CLIENT), a
plain HTML/CSS/JS board that speaks the stock wire byte for byte. The stock SpeedyChess build (a
Go/WASM page) still plays unmodified: point `--client` or `$DESKCRAB_CHESSWEB_CLIENT` at its
checkout and the protocol is the same one. Whichever directory serves, the bridge never writes a
file under it; the one server-side liberty it takes is rewriting the server-address box in
`index.html`, in memory, to the Host the page was fetched from, so connecting is one click.

## THE WIRE, AS THE STOCK CLIENT SPEAKS IT

Learned from the SpeedyChess sources; the bridge must keep to this exactly, because the client
cannot be changed.

- One WebSocket, binary messages, treated as a byte stream. Each protocol message is a type byte
  — the message's index in `chesspb.proto`: Ping 0, Join 1, NewGame 2, Move 3, Error 4, Team 5,
  Player 6, OpponentLeft 7, OpponentJoined 8, Promote 9, GameComplete 10 — then a length, then
  that many bytes of protobuf. Client→server lengths are one byte; server→client lengths are
  uvarint. A Ping is the bare type byte with no length in either direction.
- The board is `[y][x]` with y 0 at black's back rank: file = x (a is 0), rank = 8 − y.
- A Move carries from/to coordinates and a type. For type 1 (en passant) the "to" square is the
  *captured pawn's* square, not the capturing pawn's destination. Type 2 castles toward the
  a-file (queenside), type 3 toward the h-file (kingside); only the king's from-square is
  trustworthy — one stock client sends no destination at all for castles.
- Promotion is two-phase: the mover's Move puts the pawn on the last rank, the server prompts
  with Promote{x,y} (to = 0), the mover answers Promote{x,y,to} where `to` is the piece's
  Unicode rune codepoint, and the server broadcasts that Promote to everyone.
- The client applies every broadcast Move to its own board without validating it and toggles
  whose turn it is on each one. That property is what makes resume work: a stored game replayed
  as broadcasts rebuilds the client's board and turn state exactly.
- GameComplete knows three results: Stalemate 0, BlackWin 1, WhiteWin 2.

## CONTRACT

1. `betty-chessweb serve` listens on one port (`--port`, else `$DESKCRAB_CHESSWEB_PORT`, else
   8181) and answers both plain HTTP GETs — static files from the client directory — and
   WebSocket upgrades — the game protocol. The client directory is `--client`, else
   `$DESKCRAB_CHESSWEB_CLIENT`, else the shipped client at `lib/chessweb_client/` in the
   checkout, else `~/.local/share/deskcrab/chessweb/client`; if none exists the serve refuses to
   start and says what to symlink where. Explicit choices win over the shipped default, so a
   stock-client fan loses nothing. `--port 0` picks a free port and prints it.
2. `index.html` is served with the server-address box rewritten to the request's Host. No file
   under the client directory is ever written.
3. One user seat. The first connection to send Join(player) is seated and immediately told
   Player{one} and OpponentJoined — her seat needs no joining, she is always present — and then,
   when the store holds an active game, the same Team-and-replay sync an observer gets, so a
   rejoin lands on the live position with the right side to move, no NewGame click needed.
   Joining loads; it never creates or resets a game. Further Join(player)s get an Error while
   the seat is held; a seat whose socket has died is freed for the next joiner. Join(spectator)
   connections observe: they get Team and the replay at once, and every later broadcast, but
   their Moves are refused.
4. NewGame from the seat syncs the browser to the stored game: Team with the user's colour, then
   the stored move list replayed as broadcasts (a promotion replays as its Move then its
   Promote). If no game is active, one is created in the betty-chess store first — opponent from
   `--opponent`, her side from the complement of `--human-side`, which defaults to `random`.
   `random` alternates: the user gets the colour they did not have in the most recent game
   against this opponent, whatever its state, so the colours swap game after game; only the
   first game against an opponent is a coin flip. Either way the choice is made per new game,
   not once per process, so a long-lived server does not hand out one colour forever.
   NewGame while the stored game is still active creates nothing — and is never silent: the
   seat gets an Error naming the way out (Resign ends the game, then New Game deals the next),
   and the sync still follows, so a stock client that leans on NewGame as its sync loses
   nothing. `--game` pins a specific game id instead of newest-active-against-opponent.
5. An incoming user Move or Promote is translated to UCI and validated against the stored game's
   board with python-chess before anything else happens. Illegal, out-of-turn, or unseated
   attempts get an Error and change nothing — on disk or on any board. The bridge's judgement,
   not the client's, is the rules: the stock client's own move generator is known-permissive
   (its castling misses rook-moved and through-check cases), and a click it allows may still be
   refused.
6. A user pawn reaching the last rank is not recorded until its Promote answer arrives; while
   the answer is pending, other Moves are refused. The bridge broadcasts the Move at once
   (stock behaviour), prompts the mover, and on the answer records the whole UCI move and
   broadcasts the Promote. A disconnect while pending abandons the unrecorded move; the next
   sync replays the position from before it, which is the store's truth.
7. Every move recorded to the store by the bridge is followed, in order, by: broadcast to every
   connection, game-end check, and — if the game is still on — the position handed to the
   resident mover (rule 16), which answers it in-process. **No wake ever gates a move.** Two
   wakes are still booked, both consequences and never preconditions, through
   `crab wake-at --by chessweb 1s event <reason>`:
   the **post-move wake**, after a move the bridge itself posted (reflex or model) has already
   reached the store and the board — she wakes pointed at her own game, free to say one
   sentence about it to the user (never her reasoning or plans; the opponent hears
   everything she says) or to say nothing, because taking the queue out of the play path must
   not take her voice out of her own game. The post-move wake's reason is **one fixed sentence
   per game**: it names the game and where to look (`betty-chess show <id>`), never the move
   played or whose turn it is. Byte-identical reasons are the queue's own coalescing key
   ([wake-queue.md](wake-queue.md) rule 10), so while one post-move wake for a game is still
   pending — or bouncing off the run lock on the event backoff — the next move's booking and
   every deferral re-book fold into it instead of stacking behind it. The move-per-wake shape
   was measured on 2026-08-10: a wake per move into a lane that runs minutes per session held
   several bookings for one game at once, kept two of them cycling for eight minutes after
   that game had ended, and every san a reason carried was stale by delivery. The board is
   the truth she is pointed at, and it is the only copy that cannot be stale. But coalescing
   alone is NOT the one-per-game bound, and the same evening proved it: it folds only into a
   booking that is still PENDING, and this wake fires one second after it is booked, so a
   game played at browser speed books one wake per move anyway — each fired into a hot
   conversation, was held, and re-booked itself minutes out under hot-hold, until the ledger
   held 314 chessweb bookings out of 774 lines and the one wake somebody was actually waiting
   on (a finished detached job's, ringing the same queue) arrived inside that crowd. So the
   post-move booking also carries the queue's scoped per-booker cap
   ([wake-queue.md](wake-queue.md) rule 44): `--cap 1 --cap-prefix <the unique per-game head
   of the reason sentence>` — **at most one pending post-move wake per game**, counted and
   drained within that game's class alone, so one game's cap never costs another game its
   voice. Rule 44's cap drains as well as gates, soonest-first: the pending far end is
   cancelled and the booking about to fire is kept — the right end for a board, since the
   reason names no move and cannot go stale. The cap flags are inserted immediately after the
   wake command's literal `wake-at` element, ahead of the when/kind positionals (`wake_book`
   parses flags first); a `$DESKCRAB_CHESSWEB_WAKE_CMD` override that carries no `wake-at`
   has no queue to cap and is handed the reason alone, untouched. And the **end-of-game
   wake**, carrying the game id,
   how the game ended, and the movetext, because she should hear how her game finished. Neither
   wake is ever waited on: the next opponent move is answered whether or not the previous
   wake has fired. Serve start hands the position to the mover the same way when the loaded
   game is active with her to move (covers a bridge that died mid-think), and the store poll
   re-offers the position on every tick while it stays hers and unanswered — which is what
   turns a failed model call into a retry rather than a lost turn.
   `$DESKCRAB_CHESSWEB_WAKE_CMD` replaces the crab invocation for both wakes wholesale
   (the reason becomes its one argument) so tests never touch the live queue.
8. The store is watched (a poll, at most 2s late). Moves appended by another hand are
   translated and broadcast in order, exactly as if the bridge had made them. Any other change
   — a shorter list, a rewritten prefix, an undo — forces a full resync (Team + replay) of every
   connection rather than a guess at a delta.
9. When the stored game ends — checkmate, stalemate, draw rule, resignation, agreed draw,
   whether by a bridge-recorded move or noticed in the poll — every connection gets one
   GameComplete with the right result; the protocol's three results mean every draw is sent as
   Stalemate. After that, NewGame from the seat starts a fresh game (rule 4's creation path).
10. Restart loses nothing: the bridge holds no game truth outside the store, so kill it — SIGKILL
    included — restart it, rejoin from the browser, and the same game comes back: same id, same
    position, same side to move, her pending reply intact. This is the overnight property, and it
    is a consequence of rules 3, 4 and 8 rather than a feature of its own.
11. The bridge writes nothing but game files in the betty-chess store, books its one wake (the
    end-of-game one, rule 7) only through `crab wake-at`, and runs in the betty-chess venv (the
    wrapper bootstraps it the same way `betty-chess` does).
12. The browser is told where her turn stands, because a think and a mover that silently died
    look identical from a phone. The bridge keeps three stamps — asked, started, played — and
    serves them at `GET /thinking` as JSON, alongside the assistant's display name (a native
    banner has no server-side template to hand it one). The mover sets asked and started itself the moment
    the model call begins and played when the move lands, so the banner is mechanical and cannot
    be forgotten; a reflex hit sets played alone. `POST /thinking` still sets the started stamp
    for any out-of-process thinker, and the first post of a turn still sends one push
    notification (`crab notify`); the mover itself never pushes — a reply due in seconds does
    not need announcing. A small polling banner is injected into the served `index.html` ahead
    of `</body>`; the client directory itself stays unmodified (rule 3), and a client that never
    loads the banner plays exactly as before. A page whose bytes already carry `crab-thinking` —
    the shipped client renders the same state natively — is served uninjected: the marker's
    presence is the whole test, so a page that owns the banner is never given a second one.
13. Every connection is Pinged at the stock server's 25-second cadence. The stock clients hang
    up after 120 idle seconds, and a chess game is mostly idle; without the ping every browser
    drops two minutes into a think.
14. A peer reset is never fatal, wherever it lands — mid-HTTP-request, mid-upgrade, mid-read,
    or under a broadcast from the poll or keepalive thread. A socket error is contained to the
    one connection that raised it; connection-family errors log one line each, never a stack
    trace (a traceback in the serve log means a bug, not a phone roaming off the network); and
    the accept loop itself survives anything that escapes a handler. The process is still
    mortal, so `systemd/deskbetty-chessweb.service` runs the serve under the user manager with
    `Restart=always` and a short `RestartSec`, and rule 10 makes every comeback lossless. The
    bridge is never run as a background child of a shell or of one of her turns — a session's
    exit reaps its children, which is a silent way to lose the listener mid-game.
15. `betty-chess move` takes an optional `--expect-ply <n>` (and `--expect-fen <fen>`) naming the
    position the caller believed it was answering, and refuses — non-zero, nothing written — when
    the stored game is no longer there, naming the current ply and the SAN of everything played
    since. Any position handed out of process is a photograph, and the delay between the shutter
    and the reply is long enough for another mover, or another session of her, to have played:
    without the guard a legal move lands on the wrong board and the game is lost to a blunder
    nobody chose. The resident mover applies the same guard in-process (rule 16d); this flag is
    for every out-of-process caller — a reasoning session, a hand at the CLI. `--expect-fen` compares the position proper only — placement, side, castling,
    en passant — never the halfmove or fullmove counters. No expectation given, no check: every
    existing caller keeps working. `show` and `status` print the current ply, so the value is
    always at hand. And when a move given WITHOUT an expectation fails to apply while the side
    to move is not hers, `betty-chess move` MUST report it as a **turn conflict**, naming whose
    move it actually is — side and player — and, when the refused text is exactly the move
    already last on the board, saying that another hand already played it and at which ply.
    "illegal move" is the answer to a bad move on her own turn; on 2026-08-10 two of her
    sessions answered the same photograph with the same move, and the loser was told
    "illegal move: Nf3" as if she could not read a board, when the truth was that the first
    hand had already played it and the turn had passed.
15b. And `betty-chess move` MUST refuse to play **her side of a browser game**. When the loaded
    game's opponent is `browser`, the side to move is her `my_side`, and `--force` was not given,
    the move is refused — non-zero, nothing written. A browser game is answered in-process by the
    resident mover (rule 16), which pushes its reply straight into the store and never comes
    through the CLI; a hand-typed or wake-driven `betty-chess move` on such a game is a second
    mover racing the first, and rule 16d guarantees one of the two answers is discarded as stale.
    Twice on the night of 2026-08-10 an autonomous wake did exactly that while the mover was
    mid-think: the mover's own answer was thrown away and the game visibly played worse. The CLI
    is the only door an out-of-process hand can reach, so the guard lives there
    (`guard_resident_mover` in `lib/chess_cli.py`), never in the bridge — chessweb.py does not go
    through `cmd_move` and needs no exemption. A mirrored *opponent* move — the side to move not
    hers — passes untouched, as does every game whose opponent is not `browser`; `undo`, `resign`
    and every other subcommand are unaffected. `--force` is the deliberate opt-out, for when the
    mover is known to be down, and the refusal names it.
16. **The resident mover** (`lib/chess_mover.py`). The bridge answers her positions itself,
    in-process, the moment they appear — never through the wake queue, never behind the
    conversation lock, never behind a phone turn. It went through the queue once: every user
    move booked an event wake into the same single-session lane as the user's own conversation,
    so the person waiting at the board pushed her reply back every time they *talked* to her,
    and each move also rebuilt her whole prompt — state block, memory, conduct — to pick one
    chess move. Measured cost: two to five minutes per move. The mover's whole budget is
    seconds: a book move on the board inside 10, a reasoned move inside 30. Per position, in
    order:
    a. Reflex first (`chess_reflex.best_move`, specs/chess-reflex.md): a position memory knows
       well enough is played with **no model call at all** — recorded through
       `chess_cli.save_game` like any move, broadcast to every connection, stamped as played in
       the `/thinking` state, and logged as `reflex played <san> from memory` — her own played
       positions and the seeded book, recalled, not a bypass of her. A reflex move books the
       post-move wake like any move of hers (rule 7); one that ends the game broadcasts
       GameComplete (rule 9) and books the end-of-game wake instead. `DESKCRAB_CHESS_REFLEX=0`
       disables the auto-play; recording of finished games is unconditional.
    b. Otherwise **one minimal model call**. The prompt is purpose-built and tiny: the FEN, the
       side to move, the legal moves, the movetext so far, and the similarity layer's note when
       there is one (`chess_similar.reason_note`, chess-reflex.md rule 14 — computed only after
       the exact layer has missed; an empty note or a similarity failure means a bare prompt,
       and `DESKCRAB_CHESS_SIMILAR=0` switches it off). Nothing of deskcrab's prompt assembly
       rides along: no state block, no memory retrieval, no conduct sheet, no persona. The
       invocation is the measured minimal shape (tools/context-probe-results.md): `--tools ""`
       with `--strict-mcp-config --mcp-config lib/empty-mcp.json`, `--disable-slash-commands`,
       a two-line `--system-prompt`, `-p` with the prompt on stdin, a sterile cwd, auto-memory
       off. Model `$DESKCRAB_CHESS_MOVER_MODEL` (default `$CLAUDE_MODEL`, else `sonnet`);
       effort per rule 16b; per-attempt ceiling `$DESKCRAB_CHESS_MOVER_TIMEOUT` (default 90s).
    c. There is no queue. At most one position is ever being answered: a newer position arriving
       while a call is in flight kills the flight and takes the slot, and positions are
       deduplicated by `fen_key`, so the same position is never answered twice concurrently and
       a stale think is abandoned, never played.
    d. The answer is validated before it is played: parsed as UCI (SAN accepted as a fallback),
       checked legal, and posted under the hub lock only after the store has been re-read and
       still stands at the ply the call was answering — rule 15's photograph guard, applied
       in-process. A stale answer is discarded and the newest position stands to be answered.
    e. A failed attempt — a limit refusal, a timeout, no legal move in the reply — walks the
       login chain (the recorded account default first, then `$CLAUDE_FALLBACK_CONFIG_DIR` in
       order) within the same detection. A position whose every attempt failed is retried on a
       cooldown (`$DESKCRAB_CHESS_MOVER_RETRY`, default 20s) by the store poll, indefinitely:
       every failure is logged, and a turn is never silently lost.
    f. `$DESKCRAB_CHESS_MOVER_CMD` replaces the model invocation wholesale for tests — the
       prompt arrives on stdin, the reply is its stdout — so no test thinks with a real model.
16b. When rule 16a has missed and the model call is about to be made, the bridge asks the effort
    pre-check (`lib/chess_effort.py`) how hard that call should think — pure python-chess
    arithmetic, **no engine, ever**, here as everywhere in her chess — and passes the answer as
    the call's `--effort`. The classifier is consulted by default: a quiet position goes at
    `medium` and an alarming one at `high`. Setting `DESKCRAB_CHESS_ALWAYS_LOW=1` pins every
    move to `low` instead, skipping the classifier — for when reply latency matters more than
    the move. The alarms, when it is consulted: the side to move in check; a check available to either side that also wins
    material or stands in a narrow tree; one of her pieces (never a pawn, never the king) en
    prise by a simple attackers-versus-defenders count; a capture worth a rook or more available
    to either side; a pawn on its seventh rank, either side; her king's pawn shield broken or an
    open or half-open file bearing on her king while the opponent still has a rook or queen to
    use it; eight or fewer legal moves; and nearest similarity neighbours all beyond the
    distance floor when the store is deep enough to judge — genuinely new ground, worth real
    thought precisely because no memory helps. An exact reflex hit plays before the classifier
    is ever consulted, so a remembered position costs neither a model call nor a
    classification. A classifier failure — and `DESKCRAB_CHESS_EFFORT=0` — makes the call at
    the mover's default (`medium`, overridable with `DESKCRAB_CHESS_MOVER_EFFORT`): the floor
    for a normal move is `medium`, and only the explicit always-low pin reaches `low`. The
    thresholds are
    tunable: `DESKCRAB_CHESS_EFFORT_FORCED` (legal-move ceiling, default 8),
    `DESKCRAB_CHESS_EFFORT_CAPTURE` (capture-alarm floor, default 5),
    `DESKCRAB_CHESS_EFFORT_NOVEL_ROWS` (vector rows before novelty may be judged, default 500),
    `DESKCRAB_CHESS_EFFORT_NOVEL_MIN` (the similarity floor, default 0.75).
17. The move path stamps where its time went, into the same dated turn-metrics log as every
    other path (turn-pipeline.md rule 33), kind `chess`, every line's detail opening with
    `<game id> ply <n>` so one move's stamps correlate across processes — the bridge and the
    CLI write from different pids. The stages, in the order one move produces them:
    `move-start` the moment a position becomes hers to answer (a recorded user move, a NewGame,
    serve start or a poll tick with her to move — detection); then `reflex-hit` or
    `reflex-miss` when rule 16a's lookup returns (the book verdict); on a miss,
    `similar-context` (detail carrying `attached` or `empty`, and then `top <san> <similarity>`
    for the single nearest stored position — `top none` on an empty store, `top error` on a
    broken one) when the note has been computed for the model prompt — written whichever way
    that came out, so its absence proves the reflex hit short-circuited before any similarity
    work; the `top` half is recorded whether or not that neighbour cleared the note's floor,
    because a neighbour too far to be quoted is exactly the case the floor has to be judged on.
    Then `effort` with the level rule 16b chose and every reason that fired (`quiet` when none
    did, `always-low` under the pin, `default error` when the pre-check failed) — the record
    the thresholds are tuned from, absent exactly when a reflex hit short-circuited or
    `DESKCRAB_CHESS_EFFORT=0`. Then the model call's own brackets: `model-start` (detail
    naming the effort and the login attempt) and `model-end` (the elapsed seconds and the
    outcome — `ok`, or why not). A move that lands stamps `move-played` with its source —
    `reflex` from memory, `model` from the mover's call, `cli` from `betty-chess move`
    whoever ran it — and `move-latency` with the seconds from detection to the store write,
    which is the number the whole redesign is accountable to. A stale answer discarded by rule
    16d stamps `mover-stale`. Rule 33's whole discipline applies: the stamps are evidence,
    never control flow, best-effort behind their own error handling, and `TURN_METRICS=0`
    switches them off. `tools/turn-latency-report` renders the chess section per move.
18. `GET /state` answers a read-only JSON photograph of the stored game, taken under the hub
    lock on every request, never cached: the game id (or `game: null` before one exists), the
    ply, the FEN, the side to move, `your_turn` for the seat's human side, the state
    key/description/result, the last move, and — while the game is active — every legal move as
    its UCI, from- and to-square, wire move type (rule: THE WIRE) and a promotion flag. It
    exists so a page can dress the board — legal-target highlighting on pickup, a snap-back
    before a doomed send, the material panels — without growing a rules engine of its own:
    python-chess remains the one judge of chess on this machine. The endpoint is advisory and
    changes nothing; rule 5's validation of the recorded wire message stays the rules, and a
    client that never fetches it (the stock one) plays exactly as before.
19. `POST /resign` resigns the **user's** side of the loaded game — never hers: the browser can
    only give up its own seat's game. Under the hub lock the stored game is re-read; when it is
    missing or already over — or when the request body names a game (`{"game": "<id>"}`) that is
    not the one loaded, a board left open on yesterday's game — the answer is a refusal (HTTP
    409, `{"error": ...}`) and nothing is written. Otherwise `resigned_by` is recorded through
    `chess_cli.save_game`, exactly what `betty-chess resign <id> --side <the user's colour>`
    would write, every connection gets its GameComplete (rule 9), and the end-of-game wake is
    booked (rule 7) saying the user resigned from the browser. The endpoint rides HTTP like
    `/state` because the stock wire has no Resign message; the LAN-trust posture (KNOWN LIMITS)
    covers it exactly as it covers the seat itself.
20. `betty-chess move` refuses to play when the session it runs under is an **autonomous
    wake**. The CLI walks its own /proc parent chain (bounded) looking for a live session
    registration — `$DESKCRAB_STATE_PREFIX-sessions/<pid>`, whose first tab-separated field is
    the session kind — and when that kind is exactly `autonomous wake` the move is refused:
    non-zero, nothing written, the message saying a wake may look at the board but not play on
    it, because the resident mover (rule 16) owns her move. A wake that mirrors a move into a
    live game races the mover it did not know was already answering: on 2026-08-10 a wake
    played her reply itself, the mover's own answer for that ply came back and was discarded as
    stale by rule 16d, and the opponent was handed a knight for nothing. A written conduct rule
    saying the mover plays, not the wake, was violated two minutes after it was written — so
    the refusal lives in the code, not in prose. Rule 15b bars every out-of-process hand from
    her side of a *browser* game; this rule is the other axis: a wake is refused the move on
    every game, either side, browser or not. Only `move` is guarded: `show`, `status`,
    `png`, `reflex`, `similar`, `resign`, `draw` and the rest keep working from a wake, because
    looking is how a wake briefs itself. The mover is not caught: it applies her move
    in-process through `chess_cli.save_game` under the board service, never through the move
    command, and the service's ancestry holds no session registration. No registration found —
    the user's own shell, the board service, a test harness — means no refusal: the guard binds
    her wakes, nothing else. `DESKCRAB_CHESS_ALLOW_WAKE_MOVE=1` is the deliberate escape
    hatch, named in the refusal, for the one case where a human explicitly asked a wake to
    place a specific move.

## THE SHIPPED CLIENT — lib/chessweb_client/

A dependency-free HTML/CSS/JS page (`index.html`, `style.css`, `board.js`), served by rule 1 as
the default client. It speaks the stock wire exactly — client framing out (one-byte lengths,
bare Ping), server framing in (uvarint lengths, bare Ping) — so the bridge cannot tell it from
the stock page. What it owes beyond the protocol:

- **Echo-driven truth.** The client applies Moves and Promotes only as server broadcasts arrive;
  its own send is never applied optimistically. A dragged piece may *rest* on its target while
  the send is in flight, but the game state moves only on the echo, and a server Error — or a
  quiet three seconds — slides it home again. What is on screen is what the store holds, plus at
  most the stock two-phase promotion pawn.
- **The stock flow, kept.** The serveraddr box (`id="serveraddr"`, rewritten by rule 2), Connect,
  Join (player), New Game, in that order, plus Watch for rule 3's spectator join. Team sets the
  seat's colour and the board's orientation; observers watch from white's side.
- **Graveyards.** Both sides of the board: each side's captured pieces in value order with a
  running point count, and the material differential badged on the side that leads. Captures are
  read from the applied broadcasts (a regular Move onto an occupied square, the pawn an
  en-passant wire names), a Promote re-values material from the board, and a Team resync rebuilds
  both panels from zero — so a rejoin's graveyards match the store's game, always.
- **Resign, armed.** A Resign button beside New Game, live while the seat holds an active game.
  It never fires on one click: the first click arms it and says so on its own label, a second
  click within five seconds sends `POST /resign` (rule 19), and the arm falls back to safe on
  its own. The finish then arrives like any other — GameComplete off the wire, the words and
  result off `/state` — because the resign endpoint answers the store, and the store answers
  every board.
- **Movement.** Drag-and-drop and click-click both work, mouse or touch. Pickup highlights the
  legal targets rule 18 names; an illegal drop snaps back — refused locally when the legal list
  is current for the shown ply, by the server's Error otherwise. Promotion is the stock two-phase
  picker, answering with the rune of the chosen piece in the seat's colour.
- **Presentation.** Dark palette, animated piece travel and capture fades, and a layout that
  reflows for a phone (the graveyards become strips above and below the board). The console
  panel stays: every server Error and game event lands there in words. The thinking banner is
  native — the page carries its own `crab-thinking` element polling `/thinking`, which is what
  switches rule 12's injection off.
- **Self-contained.** No fetched fonts, no third-party assets; the pieces are the page's own
  inline SVG. Everything under `lib/chessweb_client/` is the repo's to edit — rule 3's
  never-write rule is about the *serving* bridge, not about this checkout.

## KNOWN LIMITS

- One game per serve. Two users wanting two boards is two serves on two ports with two
  `--opponent` names.
- Plain HTTP on the LAN, no auth: the seat is first-come. The phone server's TLS story does not
  apply here; do not expose the port beyond the LAN.
- The client's rate ceiling (nine messages a second in the stock server) is not enforced; the
  bridge trusts the LAN.
- If she moves while no browser is attached, the store is ahead of nothing — the next sync
  replays it all; but a browser left open through a laptop sleep can hold a dead seat for up to
  one join attempt before rule 3 frees it.
