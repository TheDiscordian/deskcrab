# chessweb — the browser board onto a betty-chess game

## PURPOSE

betty-chess holds a correspondence game on disk, and she plays it by running `betty-chess move`.
This module gives the *other* player a real board: a browser page where the user drags pieces,
while she keeps playing exactly as before. The bridge is a SpeedyChess-protocol server
(`lib/chessweb.py`, run through `lib/betty-chessweb`): it serves the stock SpeedyChess web client
over HTTP and speaks its wire protocol over WebSocket upgrades on the same port. It owns no game
state of its own — the betty-chess game file is the one record. The user's moves are validated and
appended there; moves appended there by any other hand (hers, via `betty-chess move`) are mirrored
into the browser; and every recorded user move books an event wake carrying the position, so she
answers in her own words and on her own clock.

The SpeedyChess client is an unmodified third-party build (a Go/WASM page). The bridge never
edits that checkout; the one server-side liberty it takes is rewriting the server-address box in
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
   `$DESKCRAB_CHESSWEB_CLIENT`, else `~/.local/share/deskcrab/chessweb/client`; if none exists
   the serve refuses to start and says what to symlink where. `--port 0` picks a free port and
   prints it.
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
   `--opponent`, her side from the complement of `--human-side` (default: the user is white).
   `--game` pins a specific game id instead of newest-active-against-opponent.
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
   connection, game-end check, and — if the game is still on — one wake booked through
   `crab wake-at --by chessweb 1s event <reason>`, the reason carrying the game id, the user's
   move in SAN, the FEN, the movetext so far, the ply the store stood at when the wake was
   booked, and the reply instruction — which carries that ply as `betty-chess move <id> <move>
   --expect-ply <n>`, so a reply worked out from a photograph that has since gone stale is
   refused rather than played (rule 15). One wake per recorded user move; never a wake for
   her own.
   Serve start books the same wake if the loaded game is active with her to move (covers a
   bridge that died before booking). `$DESKCRAB_CHESSWEB_WAKE_CMD` replaces the crab invocation
   wholesale (the reason becomes its one argument) so tests never touch the live queue.
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
11. The bridge writes nothing but game files in the betty-chess store, books wakes only through
    `crab wake-at`, and runs in the betty-chess venv (the wrapper bootstraps it the same way
    `betty-chess` does).
12. The browser is told where her turn stands, because a long think and a wake that never fired
    look identical from a phone. The bridge keeps three stamps — asked (a wake was booked),
    started (she picked the thought up), played (her move reached the board) — and serves them
    at `GET /thinking` as JSON; `POST /thinking` sets the started stamp, and the wake reason
    tells her to post it before she thinks. A small polling banner is injected into the served
    `index.html` ahead of `</body>`; the client directory itself stays unmodified (rule 3), and
    a client that never loads the banner plays exactly as before. The first `POST /thinking` of
    a turn also sends one push notification (`crab notify`), so the user learns she has started
    without watching the board; later posts in the same turn are silent.
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
    since. A wake carrying a position is a photograph, and the queue delay between the shutter
    and her hand is long enough for another mover, or another session of her, to have played:
    without the guard a legal move lands on the wrong board and the game is lost to a blunder
    nobody chose. `--expect-fen` compares the position proper only — placement, side, castling,
    en passant — never the halfmove or fullmove counters. No expectation given, no check: every
    existing caller keeps working. `show` and `status` print the current ply, so the value is
    always at hand.

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
