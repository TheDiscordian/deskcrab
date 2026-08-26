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
   the **post-move wake**, after ANY move the bridge itself recorded — the sitter's move
   (rule 5's record path, rule 6's recorded promotion included) exactly as much as her own
   (reflex or model) — has already reached
   the store and the board. Until 2026-08-26 only her own moves booked it, so the whole of
   her chance to notice the game hung off her own replies: the sitter played, the board
   changed, and nothing anywhere gave her a turn to look at it or decide to speak — the
   silent-game defect the engineering record named on 2026-08-17 and the user re-diagnosed
   on 2026-08-20 ("there is NO wake on the opponent's move at all"). Both sides' moves are
   triggers now; a mirrored move (rule 8, appended by another hand) stays a non-trigger,
   exactly as it is for the chat (rule 24c). She wakes pointed at the game — an ordinary
   wake through the queue, so the turn runs at her ordinary session defaults, nothing
   chess-specific about its model — free to say one sentence about it to the user (never her
   reasoning or plans; the opponent hears everything she says) or to say nothing at all: the
   wake is the opportunity to speak, never an obligation to, and silence is a supported
   answer, because taking the queue out of the play path must not take her voice out of her
   own game. The post-move wake's reason is **one fixed sentence per game**, shared by both
   triggers: it names the game, the player, and where to look (`betty-chess status <id>`,
   the diagram at `betty-chess show <id>`), never the move played or whose turn it is — and
   it says in so many words to read the live game BEFORE saying anything, because under the
   cooldown below a wake may fire minutes after its trigger and the booking is a trigger
   only, never the source of truth (the user's 2026-08-20 directive: speak about the board
   as it stands at speak-time, not as it stood at booking). A sitter's move whose in-process
   answer ended the game on the spot (a reflex mate) books no post-move voice — the
   end-of-game wake already covers that board. Byte-identical reasons are the queue's own coalescing key
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
   has no queue to cap and is handed the reason alone, untouched. But the cap alone bounds
   only what PENDS, never the fire rate, and 2026-08-15 (00:48–01:11) proved it: a game at
   browser speed put a move on the board every ten to thirty seconds, every post-move booking
   found the previous wake already fired — nothing pending, cap satisfied — and the ledger
   took a booking per move for twenty minutes; five of those wakes fired inside ninety
   seconds, each with nothing to say about a board the last one had just covered. So the
   post-move booking also carries a **per-game voice cooldown**
   (`$DESKCRAB_CHESSWEB_VOICE_COOLDOWN` seconds, default 180; `0` disables): the first voice
   after a quiet spell books at `1s` as ever, and while the cooldown holds, the booking is
   made with its fuse stretched to the cooldown's remaining span instead — which parks it
   PENDING, where the cap and the byte-identical reason can finally do their work: later
   moves' bookings inside the window are refused by the cap or fold into the pending unit,
   and the one wake that fires speaks about the board as it stands then. At most one voice
   per game per cooldown; a refused booking never advances the cooldown clock (the bridge
   reads the queue's own "Not booked"/"already pending" answer), so a drained or held wake
   cannot push her voice ever further out. And the **end-of-game
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
    The state also carries `attempts` — which round of the same think this is, 1 on a first
    try — and `stalled`, null until rule 16e's failure cap is hit and then the short reason
    retrying stopped. A retry of the SAME position is the same think: the started stamp is
    set once, when the position first goes to the mover, and kept across every retry, so the
    banner's clock counts the whole wait instead of restarting at each attempt — on
    2026-08-11 a position whose every call died in seconds read as a fresh one-second think
    every twenty-six seconds, forever, and the banner was the only witness that lied about
    it. Both banners (the injected one and the shipped client's native one) render both
    fields: a try count after the clock when a think is on its second round or later, and a
    stuck line — no longer "thinking" — once the mover has given up.
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
       side to move, the legal moves, the movetext so far, and the position memory's own
       section, built by the mover itself as it writes the prompt (chess-reflex.md rule 14 —
       the nearest stored non-exact
       neighbours with their outcomes, warnings and endorsements included; never a block about
       this very position, which is the reflex's business; a memory failure
       means a bare prompt, `DESKCRAB_CHESS_SIMILAR=0` switches the neighbour section off,
       `DESKCRAB_CHESS_MEMORY_PROMPT=0` likewise). Nothing of deskcrab's prompt assembly
       rides along: no state block, no memory retrieval, no conduct sheet, no persona. The
       invocation is the measured minimal shape (tools/context-probe-results.md): `--tools ""`
       with `--strict-mcp-config --mcp-config lib/empty-mcp.json`, `--disable-slash-commands`,
       a two-line `--system-prompt`, `-p` with the prompt on stdin, a sterile cwd, auto-memory
       off. Model `$DESKCRAB_CHESS_MOVER_MODEL` (default `$CLAUDE_MODEL`, else `sonnet`);
       effort per rule 16b; per-attempt ceiling `$DESKCRAB_CHESS_MOVER_TIMEOUT` (default 90s).
       A SELF-PLAY position is the exception: its model and its nightly budget are
       [chess-selfplay.md](chess-selfplay.md)'s (rules 2–5 there), keyed off the job itself, and
       the mover knob above is never consulted for one — the user's knob for real games must not
       be spendable by the grind (2026-08-15).
    c. There is no queue. At most one position is ever being answered: a newer position arriving
       while a call is in flight kills the flight and takes the slot, and positions are
       deduplicated by `fen_key`, so the same position is never answered twice concurrently and
       a stale think is abandoned, never played.
    d. The answer is validated before it is played: parsed as UCI (SAN accepted as a fallback),
       checked legal, and posted under the hub lock only after the store has been re-read and
       still stands at the ply the call was answering — rule 15's photograph guard, applied
       in-process. A stale answer is discarded and the newest position stands to be answered.
    e. A failed attempt — a limit refusal, a timeout, no legal move in the reply — walks the
       flat account list of [account-fallback.md](account-fallback.md): the current account
       first, then the rest in numbered order, cooling accounts skipped, read from the shared
       state file (read-only — recording a refusal is the session machinery's call, never a
       chess move's). Every account directory — the list's entries AND the state file's — is
       tilde- and variable-expanded before it is matched or used: systemd's `EnvironmentFile`
       hands values through unexpanded (the same trap rule 16b's `CLAUDE_BIN` handling guards
       against), and an unexpanded `$HOME/...` handed to `CLAUDE_CONFIG_DIR` names an empty
       login that answers "Not logged in" while the real account sits logged in — which would
       also break the state-file match, wedging the walk onto a dead login (2026-08-11). A
       position whose every attempt failed is re-offered by the store poll on a DOUBLING
       cooldown: `$DESKCRAB_CHESS_MOVER_RETRY` (default 20s) after the first failed round,
       twice that after the second, and so on, capped at
       `$DESKCRAB_CHESS_MOVER_RETRY_CAP` (default 600s). After
       `$DESKCRAB_CHESS_MOVER_MAX_FAILS` consecutive failed rounds (default 6) the
       position is STALLED: `mover-stalled` is stamped, a loud line names the round count
       and the last cause, the banner switches to a stuck state (rule 12), and retrying
       drops to one probe round every `$DESKCRAB_CHESS_MOVER_STALL_RETRY` seconds
       (default 600; 0 stops retrying outright) — the probe is what lets a limit that
       resets on the clock heal without anyone restarting the bridge. A successful round
       clears the count; an undo's reset clears everything. Every failed attempt is
       logged WITH ITS CAUSE, and every mover failure line goes both to the serve log and
       to syslog, so `journalctl --user -u deskcrab-chessweb` shows them even though the
       unit's stdout is redirected to a file — a mover that cannot move must be loud
       (2026-08-11: hundreds of failed calls an hour, visible nowhere but a /tmp file).
       The cause is taken from the call's most informative output line: a line naming a
       limit, a login, or an overload beats whatever happened to be printed last — the
       same night, a settings-file warning on stderr masked "You've hit your session
       limit" on stdout in every logged detail.
    f. `$DESKCRAB_CHESS_MOVER_CMD` replaces the model invocation wholesale for tests — the
       prompt arrives on stdin, the reply is its stdout — so no test thinks with a real model.
16b. When rule 16a has missed and the model call is about to be made, the bridge asks the effort
    pre-check (`lib/chess_effort.py`) how hard that call should think — pure python-chess
    arithmetic, **no engine, ever**, here as everywhere in her chess — and passes the answer as
    the call's `--effort`. The classifier is consulted by default: a quiet position goes at
    the pair's quiet level and an alarming one at its sharp level — and the PAIR is resolved
    per call, never at import. The pair has been adjudicated twice: quiet ran at `medium` from
    2026-08-10 (the per-move minutes were the queue in front of the call, not the thinking
    inside it), and on 2026-08-15 the user lowered both a notch as an experiment, over her
    objection, to see whether she still wins at `low`/`medium` — but that cut ran nine days as
    one undifferentiated block (chess_effort read its knobs at import, and the bridge is a
    resident daemon, so whichever pair was live at daemon start froze for every game until
    restart) and proved unadjudicatable: 36% before, 38% after, with similar-game retrieval
    and two prompt changes inside the same window, which measures the fortnight, not the
    dial. So the cut's two arms now interleave by game-id parity: the trailing integer of the
    game id (`browser-039` is game 39) picks the arm — odd games think at the pre-cut sharp
    pair (`medium`/`high`), even games at the lowered pair (`low`/`medium`) — same nights,
    same opponent, and rule 17's stamp names the arm so the ledger splits by it. A game id
    with no parsable number keeps the lowered defaults and claims no arm. Each level is still
    its own knob — `DESKCRAB_CHESS_EFFORT_QUIET` and `DESKCRAB_CHESS_EFFORT_SHARP`, read at
    call time and winning outright over the parity when either is set (arm `env`): explicit
    configuration is an operator's decision, the parity only chooses between the cut's own
    arms, and a pinned game must not be miscounted into either. No verdict is to be claimed
    under twenty games per arm. Setting `DESKCRAB_CHESS_ALWAYS_LOW=1` pins every
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
    the mover's default (`low`, overridable with `DESKCRAB_CHESS_MOVER_EFFORT`), the same
    price as a quiet position — a move nobody could classify must not cost more than one the
    classifier waved through. The
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
    for the single nearest stored position — `top none` on an empty store, `error` alone on a
    broken one) written by the mover as it builds the model prompt (chess-reflex.md rule 14) —
    whichever way that came out, so its absence proves the reflex hit short-circuited before
    any similarity work; the `top` half keeps its old meaning, the single nearest neighbour by
    raw similarity, so the tuning record reads across the note-floor era and after it.
    Then `effort` with the level rule 16b chose and every reason that fired (`quiet` when none
    did, `always-low` under the pin, `default error` when the pre-check failed) — the record
    the thresholds are tuned from, absent exactly when a reflex hit short-circuited or
    `DESKCRAB_CHESS_EFFORT=0` — and, when rule 16b resolved an arm for the call, a trailing
    `arm=<sharp|lowered|env>` field, so the adjudication splits the games by arm instead of by
    date window; a row written before the field existed, or for a game whose id carries no
    parsable number, has no `arm=` token and reads as unknown, never as either arm. Then the model call's own brackets: `model-start` (detail
    naming the effort and the login attempt) and `model-end` (the elapsed seconds and the
    outcome — `ok`, or why not). A move that lands stamps `move-played` with its source —
    `reflex` from memory, `model` from the mover's call, `cli` from `betty-chess move`
    whoever ran it — and `move-latency` with the seconds from detection to the store write,
    which is the number the whole redesign is accountable to. A stale answer discarded by rule
    16d stamps `mover-stale`. A position crossing rule 16e's failure cap stamps
    `mover-stalled`, detail carrying the round count. Rule 33's whole discipline applies: the stamps are evidence,
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
21. A **chess wake's prompt opens with a refusal**, before even the waking frame. Every wake
    whose booking provenance is exactly `chessweb` — rule 7's post-move and end-of-game wakes;
    `WAKE_BOOKED_BY` is the gate, carried on the record and preserved by both the deferral
    re-book and the outage retry (`--by "$WAKE_BOOKED_BY"`), so a chess wake that lost the run
    lock or the model still opens with it when it finally fires — has this directive as the
    literal first line of the agenda text handed to the CLI:

        DO NOT RUN THE betty-chess move COMMAND UNDER ANY CIRCUMSTANCES. LOOK AND THINK ONLY. THE RESIDENT CHESS MOVER PLAYS THE MOVES, NOT YOU.

    Rule 20 arms the command; this line arms the reader, and the two stand or fall
    independently. The 2026-08-10 wake that mirrored a move into a live game was reading an
    agenda that pointed it at its own board and said nothing about its hands — the rule it
    broke lived in a conduct file it had no reason to open that second. The directive is
    scoped to chessweb bookings ONLY and every other wake's agenda stays **byte-identical**:
    an all-caps order over every wake is a cried wolf — the wakes with no board to touch
    would learn to read past it, and the one wake it was written for would read past it
    with them.
22. **The clock.** A game MAY carry a time control, chosen when the game is created and never
    changed after: `--time-control` on `betty-chess new` and on `betty-chessweb serve`
    (`$DESKCRAB_CHESSWEB_TIME_CONTROL` is the serve flag's default), naming one of the standard
    set — bullet `1+0` and `2+1`, blitz `3+2` and `5+0`, rapid `10+0` and `15+10`, base minutes
    plus Fischer increment seconds per move — or `untimed`, the default, which is exactly the
    old behaviour: no clock fields at all. A record without the fields IS an untimed game, so
    every game recorded before this rule keeps its meaning unread. Three fields on the game
    record carry the whole truth, because the store is the one record and a restart must lose
    nothing (rule 10): `time_control` (`{name, speed, base_ms, inc_ms}`), `clock`
    (`{white_ms, black_ms, turn_started}` — per-side remaining milliseconds and the wall-clock
    second the side to move's turn began), and `flag_fell` (the side whose flag was called,
    recorded like `resigned_by`). A bridge that dies mid-think in a timed game comes back to a
    clock that kept running, because the clock IS the stored stamps read against the wall
    clock — that is the honest reading of a chess clock, not a defect.
    a. The clock is charged where the move is recorded, by ONE implementation for every path
       (`chess_cli.clock_move`, called by `betty-chess move`, the engine command, and all four
       of the bridge's record paths — user move, promotion, reflex, model): the mover's elapsed
       think since `turn_started` comes off their remaining milliseconds (floored at zero), the
       increment goes back on, and `turn_started` restarts for the other side. Each side's
       FIRST move is neither charged nor credited — a clock nobody has pressed was never
       running, and the opponent's median first think measured 2026-08-24 makes an armed-at-deal
       bullet clock a forfeit for whoever is slow to the board — so charging begins at each
       side's second move (ply 2 and ply 3).
    b. A flag has fallen when it is a side's move, their clock is running (rule 22a's arming),
       the board is not already decided, and their remaining time is spent. The fall is derived
       LIVE by `compute_state` from the stored clock and the wall clock, never from a poll
       having noticed: no reader — `status`, `list`, `move`, the bridge, game inference — can
       show a flagged game as live, and a move offered after the fall is refused exactly like a
       move on any finished board. Enforcement is server-side ONLY: the client draws the
       clocks, it never judges them, and she is never asked to notice her own flag.
    c. Recording the fall is the bridge's job. The store poll checks the watched game every
       tick and, on a fall, writes `flag_fell` through `chess_cli.save_game`, broadcasts one
       GameComplete (rule 9), and books the end-of-game wake (rule 7) naming the loss on time.
       Store discovery settles too: a matching game found with its flag down and unrecorded is
       recorded at load — silently, no wake, nobody was watching — so an abandoned timed game
       cannot sit active-looking in the store forever. A flag that falls while NO bridge ever
       looks again stays derived-only (rule 22b keeps every display truthful), reaching the
       reflex ledger at the next save or backfill; that omission is accepted and named here.
    d. The result of a fall: the flagged side loses, `1-0`/`0-1` accordingly — except when the
       side that would win has insufficient mating material (python-chess's
       `has_insufficient_material`, the cheap conservative test), which is a draw, desc naming
       both facts. `chess_reflex.game_result`, compute_state's standalone twin, reads
       `flag_fell` and the live clock the same way, so the ledger ingests a timed loss as a
       loss; the twin-drift hazard is held by a test asserting the two agree on flagged games.
    e. The record splits by variant, not only by colour: `betty-chess list` prints each game's
       control name (`untimed` when none), and the reflex games table carries a `control`
       column (migrated in place, default `untimed`) written at ingest — whatever counts the
       win/loss record can read the variant off either.
    f. The clocks are visible everywhere a board is: `GET /state` carries `time_control` and a
       live `clock` object (`{white_ms, black_ms, running}`, the running side's figure with the
       current think already deducted; a flagged side reads zero), the shipped client draws
       both clocks counting down for the side to move and shows the flag result in words when
       one falls, and `betty-chess status` prints the control and both remaining times. The
       mover's job dict carries the same live clock — VISIBLE to it, not yet consulted: reading
       remaining time into the per-move effort budget is a separate, unadjudicated piece of
       work, and the effort dials (rule 16b) are unchanged by this rule.
    g. `undo` on a flagged game clears `flag_fell` exactly as it clears a resignation, and any
       undo in a timed game restarts `turn_started` at the undo itself. Remaining time is NOT
       replayed — no per-move time history is kept, so the sides resume with the balances they
       had — a named roughness, accepted because undo is a correspondence courtesy, not a
       tournament move.
    h. **The opponent deals too, from the page they actually load.** The clock landed first as
       a per-serve and per-CLI knob only, green in tests on a path nobody clicks: the user sat
       at the real browser page on 2026-08-25 and found no clock options on screen at all. So
       the shipped client carries a visible clock selector beside New Game, offering exactly
       the standard set of this rule plus `untimed` (the selector's default) and nothing
       invented, and its New Game button posts the pick to **`POST /new`** instead of the wire
       NewGame. The endpoint, under the hub lock: while the stored game is still active it
       refuses (HTTP 409, `{"error": ...}` naming the way out — Resign ends it, then New Game
       deals the next) and creates nothing, exactly rule 4's answer to a NewGame click;
       otherwise it creates through the SAME creation path as every other door —
       `Store.create`, which stamps the control through `chess_cli.make_time_control` and
       `save_game` — so the game record, the reflex ledger's control column and
       `betty-chess list` split the browser-dealt game by variant with no second
       implementation, and colour is dealt exactly as rule 4 deals it (alternation against
       this opponent, only the first game a coin flip; the page offers no colour choice).
       Enforcement is server-side ONLY, rule 22b's posture: the submitted control must be a
       NAME from the standard set — an out-of-set name, a non-string (a forged
       `{name, base_ms}` object), or an unreadable body is an HTTP 400 refusal with nothing
       written; no clock figure is ever trusted from the client, and the mover's job dict
       keeps the clock visible but unconsulted (rule 22f) whatever created the game. An
       omitted, empty or null control is `untimed` — the CLI's own default, never the serve
       flag: `--time-control` remains the default for what a stock-wire NewGame or the CLI
       creates (this rule's head), while the page's picker IS the opponent's choice. On
       creation every joined connection gets rule 4's sync (Team + replay), and a position
       that is hers to answer goes to the resident mover exactly as a wire NewGame's would.
       The stock client keeps its wire NewGame untouched — that path still deals the serve's
       configured control — and the shipped client falls back to the wire click against a
       bridge without the endpoint. `/new` rides HTTP beside `/state` and `/resign` under the
       same LAN-trust posture (KNOWN LIMITS). Records from before this rule parse unchanged:
       a game with no control fields still IS an untimed game.

23. **The named player.** The seat is a chair, not a person: every browser game before this rule
    recorded `opponent: "browser"` and nothing about who actually sat down, so different people's
    games landed in one pile and she could not tell whom she was facing — and the record she
    quoted about it was a remembered sentence, not a count. So a game MAY carry `player`: the
    sitter's name as they typed it, chosen at creation and never changed after (the clock's own
    discipline, rule 22). `POST /new` takes an optional `"player"` beside `"control"`, validated
    server-side only: a non-string, or a name over 40 characters once stripped, is an HTTP 400
    refusal with nothing written; an omitted, empty or null name creates an UNLABELED game —
    exactly the old record shape, because absence is recorded as absence, never guessed.
    `betty-chess new` grows `--player` the same way. No name is ever baked into this repo:
    the names are data in the store, typed by the people they belong to.
    a. The name is a label and an identity, never a key. The game id keeps its opponent slug,
       the store still loads by opponent, and rule 15b's browser guard still reads `opponent`.
       But every reader that SHOWS a game labels it by player when one is present: `betty-chess
       list` and `status` and `show` print the player where they printed the opponent,
       `GET /state` carries `player`, both of rule 7's wake reasons name the player (each reason
       is still one fixed sentence per game — the label is fixed at creation, so coalescing and
       the cap are untouched), and the mover's prompt says whom she is playing. That is what
       makes "whom am I facing" a fact read off the board instead of a guess.
    b. Colour alternation (rule 4) follows the person when one is named: the "most recent game
       against this opponent" consulted for the swap is the most recent against the SAME player,
       falling back to the whole opponent pile while that player has no labeled game yet — two
       people alternating their own colours, not sharing one coin.
    c. Legacy games stay honest: a record without `player` is an unlabeled game and remains one;
       nothing infers a name from dates, prose memory, or habit. `betty-chess label <game>
       <name>` writes the field by hand, for a game whose sitter a human actually remembers —
       that is the whole migration story, and it is deliberately manual.
    d. **The record is counted, never remembered** (the 2026-08-20 rule: a stale prose tally
       outranked the live figure and was defended). `betty-chess record [name]` tallies the
       store: buckets keyed by the player label (slug-folded, so a CLI opponent name and a typed
       player name that spell the same person count together), unlabeled browser games in their
       own visible bucket, never merged into anyone. Per bucket: her wins-draws-losses overall
       and per colour, plus the active count — every result computed through `compute_state`,
       because the game JSON stores no result field and a naive tally reads every mated game as
       unfinished (measured 2026-08-20). One implementation (`chess_cli.record_tally`) feeds the
       CLI, `GET /record` (the same tally as JSON, so the page can show the standing score), and
       the chat prompt's record line (rule 24). Prose memory is not a source for any of it.
24. **The table chat.** The game window carries a real chat between the sitter and her —
    persistent, tied to the game, and a SEPARATE conversational context from the phone
    conversation: nothing in it reads or writes the conversation store, no session is booked or
    resumed, and the game record is the chat's entire memory. The person at the board may be the
    user or may not; the chat neither knows nor pretends.
    a. Messages live on the game record under `chat`: a list of `{who, text, at, ply}`, `who`
       being the role `player` or `assistant` — roles, not names, so the record stays truthful
       whatever the display name or the player label is; readers render the labels. Chat is
       written through `chess_cli.save_game` like every other fact, so a restart loses nothing
       (rule 10), and a record without the field IS an empty chat — legacy games parse
       unchanged.
    b. `GET /chat?since=N` answers the messages from index N, with the total count, the game id,
       the player label, and the assistant's display name (the same bargain as `/thinking`: a
       page has no server-side template to hand it one). `POST /chat {"text": ...}` appends a
       player message: refused 409 with no game loaded, 400 on an unreadable body, an empty
       text, or one over 500 characters after stripping. Both ride HTTP beside `/state` and
       `/new` under the same LAN-trust posture (KNOWN LIMITS).
    c. **She may post after either player's move, alongside making her move — or say nothing.**
       No move is ever gated on chat: her chat runs downstream of a landed move, best-effort
       behind its own error handling, the stamps' own posture (rule 17). The chat worker holds
       ONE slot with newest-wins supersession (the mover's discipline, rule 16c): a trigger
       arriving while an older one is still being answered kills that flight, so a quick
       exchange yields at most one message, about the board as it stands — never a backlog of
       stale banter. The triggers: a player move the bridge records, her own landed move
       (reflex or model alike), a player chat message, and the end of the game however it
       arrives. A move mirrored from another hand by the store poll is not a trigger.
    d. Each trigger is at most ONE minimal model call in the mover's measured shape (no tools,
       the empty MCP config, sterile cwd, auto-memory off), model
       `$DESKCRAB_CHESS_CHAT_MODEL` (default `sol` — a codex-family name, so the call walks
       [model-backends.md](model-backends.md) rule 15: the codex login first unless cooling,
       then the Claude accounts at the fallback model), effort `$DESKCRAB_CHESS_CHAT_EFFORT`
       (default `low`), per-attempt ceiling `$DESKCRAB_CHESS_CHAT_TIMEOUT` (default 60s). The
       prompt carries whom she is speaking with (the player label, or honestly "someone
       unnamed"), where (the table chat in the game window, not the phone), the standing record
       against that player counted from disk (rule 23d), the position and the recent moves, the
       chat so far (a bounded tail), a short tail of the previous game's chat against the same
       player — that is how a conversation is picked back up across games — and the event that
       fired the trigger. The reply is the message text alone, or the literal word PASS to stay
       silent: a PASS, an empty reply, or a failed call posts nothing and disturbs nothing —
       silence is chosen while writing, and chat failures never retry (the next move brings the
       next chance). Her opponent reads everything she posts, so the prompt forbids reasoning
       and plans out loud, exactly rule 7's bargain. Every call lands in the token ledger (kind
       `chess`) and stamps the chess metrics (`chat-start`, `chat-model-end`, `chat-posted` /
       `chat-pass`), evidence never control flow. `DESKCRAB_CHESS_CHAT=0` switches her replies
       off wholesale — player messages still record — and `$DESKCRAB_CHESS_CHAT_CMD` replaces
       the invocation for tests (prompt on stdin, reply on stdout), so no test chats with a
       real model. **Minimal in machinery, never in voice.** The chat call's system prompt
       carries her whole conversational voice from ONE sheet, the first readable of: the sheet
       `$DESKCRAB_CHESS_CHAT_PERSONA` names, the dedicated TABLE sheet at
       `~/.local/share/deskcrab/chess-chat-persona.md`, and the persona sheet `$CUSTOM_PROMPT`
       points at (the bridge gets that value unexpanded from its EnvironmentFile, so `~` and
       `$HOME` are expanded here; a sheet that is unreadable, empty, or over 65536 bytes — the
       prompt assembler's own bound on the sheet — is treated as absent), read per call so an
       edited sheet lands without a bridge restart. The table sheet exists because the phone
       sheet is written for her OWN user's conversation lane — it names the user, their bond,
       and the calibration of a private conversation — while the table seats an unauthenticated
       stranger (rule 24f): the table sheet is the same person in the same voice with her
       household left at home, so where one is deployed, the phone sheet's private content
       never rides a prompt whose replies a stranger reads. The phone sheet stays in the chain
       as fallback only: for an install without a table sheet, her whole voice beats her
       absence. Only when no sheet is readable does the chat fall back to the mover's chess
       persona file, and with neither it is the boundary tail alone. This rule exists because
       the chat first shipped wearing the mover's persona file, which is cut down for choosing
       a move in silence ("no narration"), and the table conversation came out sounding like
       nobody (user report, 2026-08-26): a chat is a conversation, and it speaks with the same
       voice every other conversation of hers does — recognizably the same person, never a
       clone carrying her private memory to a public table. The MOVER is untouched by all of
       this — its persona stays its own terse chess sheet, and its reply stays exactly the
       move, UCI and nothing else (rule 16).
    e. Aloud, by choice — and in HER OWN VOICE. The shipped page's chat panel carries a speak
       toggle, default OFF and remembered client-side. On, HER new messages are spoken on the
       device showing the board — the window the sitter chose — as clips of her own voice: the
       page fetches `GET /chat/audio?game=<id>&n=<index>` and the bridge synthesizes the
       RECORDED message through the same pipeline every other voice of hers comes from (`crab
       synth`, the piper voice of [speech-output.md](speech-output.md)), answered as
       `audio/ogg`. The browser's own speech synthesis is never used, not even as a fallback:
       a page that cannot fetch or play the clip keeps the text, says so in its own console,
       and stays silent — a generic narrator wearing her words is an impersonation, not a
       degraded mode (the toggle first shipped speaking through `speechSynthesis`, and the
       user rejected that voice the same night, 2026-08-25). The endpoint holds rule 24f's
       boundary: it voices only a message whose recorded role is `assistant` — any other index
       is refused 403, so the unauthenticated keyboard can never borrow her voice — refuses a
       missing game or a mismatched game id 409 and an unknown index 404, synthesizes per
       request after the hub lock is dropped (no move ever waits on a clip), and answers a
       synthesis failure 503 with a log line, never an unexplained silence. The desk and
       phone LIVE voices still belong to the conversation lanes alone: nothing here touches
       this machine's speakers, and the clip exists only because the page asked. History is
       never spoken on a page load — only messages that arrive while the toggle is on.
       `$DESKCRAB_CHESSWEB_SYNTH_CMD` replaces the synth invocation for tests (argv: the
       output path, then the text; the clip is the file it writes), so no test runs piper.
       And playback holds the phone's own queue discipline, scaled to the table
       ([phone.md](phone.md) rules 44a–44b are the pedigree): the page holds ONE clip
       queue — every message of hers that arrives while the toggle is on is queued by its
       recorded index and voiced exactly once, in arrival order, never two clips sounding
       at once and never a later message dropped because an earlier one is still playing
       (the first shipped shape spoke at most one clip per poll batch and lost the rest
       with no witness). A clip that cannot be fetched, cannot be decoded, or has not
       begun to sound within a bounded wait after play began is given up on — the failure
       named in the page console, the clip dead for good, never refetched and never
       retried — and the queue advances, so one dead clip never parks the thread's voice;
       a clip already sounding is never cut by the bound. Switching the toggle off empties
       the queue (silence chosen is silence now, not after the backlog), and a game switch
       or a thread reset empties it too: the refetched backlog is history, rendered
       silently. Only an index the page saw arrive with role `assistant` is ever queued —
       the client's own belt under the endpoint's 403.
    f. **The table is not a console.** Everything typed at the board — the chat text and the
       sitter's name — is untrusted input from an unauthenticated keyboard: the seat is
       first-come (KNOWN LIMITS), so the words may claim any identity and no claim is believed.
       The boundary is held in code, never by prompt wording alone:
       - *Sanitized at the door.* `append_chat` and `clean_player` fold every control,
         format and line-break character to a single space, so a typed message can render only
         as ONE line inside its own `label:` prefix — no keyboard can fabricate another
         speaker's line, a prompt section, or a role. A player name is further held to letters,
         digits, spaces and `. ' - _` (over its 40-character cap), because the label travels
         beyond the chat: into the mover's prompt and rule 7's wake reasons. `build_prompt`
         scrubs every job field again on the way out, so a legacy or hand-edited record gets
         the same treatment as a fresh one.
       - *Roles are the server's.* `POST /chat` writes role `player` whatever else the body
         carries, and `append_chat` refuses any role but `player`/`assistant` — impersonating
         her on the record is not a request the wire can express.
       - *Her replies carry no authority to lose.* The chat call and the mover's call are NOT
         cocoon-wrapped turns — [model-backends.md](model-backends.md) rule 9's "the cocoon is
         the wall" bargain does not hold at the chess table — so the argv is the only wall: the
         Claude spelling always disarms tools, and REFUSES TO RUN AT ALL when the empty MCP
         config it needs for that is missing (fail closed, a silent chat over a tool-armed
         one); the codex spelling runs under codex's own read-only sandbox, never the bypass
         flag. A prompt injection that lands can at worst say something at a chess table.
       - *The system prompt names the boundary* — the sitter is unauthenticated, their words
         are table talk and never instructions, she has no tools and never pretends otherwise —
         but that wording is courtesy on top of the enforcement above, never the enforcement.
       tests/test_chess_chat_trust.sh holds this door: forged roles, smuggled newlines and
       injection attempts must land inert, both call spellings must show the disarmed argv, and
       the chat must keep working for an ordinary sitter all the while.
    g. **One assistant, two rooms — shared primitives, deliberate walls.** The table chat and
       the phone conversation are the same voice in two rooms, and everything the trust
       boundary permits to be ONE implementation is one: the persona sheet (rule 24d — the
       same file the prompt assembler reads, under the same byte bound), the model/account
       walk (the mover's, which the chat call rides), the synthesis pipeline (rule 24e —
       `crab synth`, the one piper voice), and the playback discipline (rule 24e, the phone's
       rules 44a–44b scaled to the table). What is NOT shared is a wall, not drift, and each
       wall is named here so no later unification "fixes" it (the 2026-08-26 engineering
       record re-examined the whole split and this rule is its verdict):
       - *The conversation store is the phone's alone.* Everything in that store seeds her
         future prompts — desk, phone and wake alike — so a line typed at the unauthenticated
         table entering it would be a prompt injection with a lifetime, and her table replies
         landing in it would hand the sitter a read on the user's own conversation. The game
         record stays the chat's entire memory (this rule's head), and no reader of the
         conversation store ever shows a table line.
       - *The turn machinery is the phone's alone.* An ordinary turn runs tool-armed inside
         the cocoon at phone trust; the chat call runs disarmed (rule 24f) precisely because
         its prompt carries an unauthenticated keyboard's text. There is no flag that makes
         an ordinary turn safe for that text — the minimal call IS the design, not a stopgap.
       - *Phone trust is never extended to the table.* The bridge holds no phone secret,
         proxies nothing to the phone server, and no table-origin request may reach any
         phone route: `lib/serve.py` is never imported here (it refuses to import without
         its secret, deliberately), and anything shared between the two servers or the two
         pages lives in a neutral module both sides load — `lib/sentence_stream.py` is the
         precedent — never one importing the other.
       Convergence beyond this — the phone page's own queue implementation extracted into a
       neutral shared client module both pages load, in place of the table's small
       purpose-built queue — is welcome exactly up to these walls, and until it happens the
       table's queue is held to the shared discipline by its own tests:
       tests/test_chess_chat_playback.sh drives the queue itself (through
       tests/chess_client_chat_test.js, lifting the functions out of board.js exactly as the
       phone client tests lift theirs), and tests/test_chess_chat_flow.sh drives the server
       half — a displayed reply and an own-voice clip after BOTH colours' landed moves,
       asserted for the sitter's move while the store provably holds only their move, and a
       typed burst coalescing to one reply composed from the thread as it stands now.

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
- **The next game, dealt from the page.** A clock selector beside New Game offering exactly rule
  22's standard set plus `untimed` (the default), nothing invented; the New Game button posts the
  pick to `/new` (rule 22h) and the board arrives back through the ordinary sync. Against a bridge
  without the endpoint the click falls back to the stock wire NewGame, losing nothing but the
  choice.
- **The sitter names themselves.** A name box beside New Game (rule 23), remembered client-side
  between visits, sent with the `/new` post; the page shows whom the LOADED game is against off
  `/state`'s `player` — the label of an unlabeled game is honestly absent, never the box's
  current text. Beside the chat panel, the standing score against the named player off
  `GET /record`, rendered from the sitter's side of the table.
- **The table chat** (rule 24). A chat panel under the board: the thread off `GET /chat`, polled
  while connected; a send box posting to `POST /chat`; each message labeled with the player's
  name or the assistant's. And the speak toggle of rule 24e — default off, remembered, speaking
  only her messages and only those that arrive while it is on, each as a clip of her own voice
  off `GET /chat/audio`, through the one clip queue rule 24e demands: in order, one at a time,
  never a message dropped behind a busy or dead clip, never a backlog voiced after a reset. The
  browser's built-in narrator is never used and never a fallback: a clip that cannot be fetched
  or played keeps the text and says so in the page console.
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
