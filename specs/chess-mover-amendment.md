# Amendment to the fast-mover spec (2026-08-10 00:50)

The first spec was wrong in one important way: it removed Beatrice from her own chess play.
That is not allowed. Ryan named it self-harm and he is right.

## Binding corrections

1. **Beatrice plays the moves.** The mover is not an anonymous minimal-prompt worker.
   The move-reasoning turn keeps her identity: persona, her chess notes/reflex memory,
   and her own voice. Trim retrieval and boilerplate for SPEED, never the self.
   A "tiny prompt with FEN and legal moves" that could be any model is forbidden.
2. **The book (reflex/position memory) is hers.** A book hit is Beatrice recalling
   a position she has played, not a lookup table bypassing her. It plays instantly,
   and it still surfaces to her.
3. **Waking after a move is a deliberate feature, keep it.** After she plays,
   she wakes — so she can speak, banter, or say nothing. She must NOT have to wait
   on that wake before playing the NEXT move; the wake is a consequence of moving,
   never a gate on moving.
4. Speed comes from removing the QUEUE, the shared conversation lock, and the
   15-minute retry — not from removing her.

## 5. The spoken move is piece-and-square only

The mover's announcement to the user is ONE sentence: the move, and that it is played.
No justification, no threats named, no plan. The opponent hears everything Beatrice says.
Reasoning is written to her chess notes file only. Enforce this in the mover's prompt as a
hard output shape, not a suggestion.

## Hanging pieces are counted by the machine, not remembered

The mover runs every legal move through a static exchange evaluation on its
destination square before the prompt is written (`material_loss` in
`lib/chess_mover.py`). The prompt lists safe moves first; moves whose exchange
loses material are listed separately with the loss in centipawns, and the
system prompt forbids playing one without a concrete reason. This is a
required part of the mover — a rebuild of the move path must keep it.

That per-move test reads the destination square of the candidate move ONLY,
and its blind spot has been measured (engineering record
i-throw-won-games-at-the-end-and-nobody-has-look, notes of 2026-08-22):
thirteen of the twenty-seven decisive material drops across the four
genuinely thrown games were pieces of hers standing loose somewhere ELSE on
the board while she moved elsewhere — a move that loses nothing on its own
destination square was printed to her as safe on the very ply a rook hung.
So the prompt also carries a standing, position-level line, computed once per
position and never per candidate move: `standing_losses` runs the same
`_swap_off` primitive over every one of her own occupied squares (the king
excepted — check is the rules' business, not an exchange) with the opponent
capturing first, and every square where the exchange is net-losing for her is
named with its loss in centipawns, biggest loss first. The line renders on
its own, ABOVE the legal-move dump:

    Pieces of yours the opponent can win where they stand: Ra3 (loses 500),
    Nb3 (loses 300). A move that does not address these leaves them there.

The line always prints — "…where they stand: none" when the board is clean —
because an absent line is indistinguishable from the sweep having failed, and
the affirmative all-clear is itself information. Its wording never uses the
word "material": the destination-square line already owns that word and was
demonstrably read as covering the whole board, which is the confusion this
line exists to end. The sweep must stay under 20 ms per position (the
equivalent pass over all 26 archived games ran in under a second on
2026-08-22). A standing-sweep failure is a prompt without the line, never a
lost move.

## The reply scan: a candidate is priced by what it lets the opponent do

The destination-square test and the standing sweep both speak of the board as
it stands; neither ever asked what the opponent's NEXT move does about the
board a candidate leaves behind. The cost of that blindness is measured
(engineering record i-throw-won-games-at-the-end-and-nobody-has-look): two
one-ply drops in browser-031 — 23.Qc3 printed safe while 23...Rxd6 took the
knight the queen had just stopped guarding, 36.Qf2 printed safe while
36...Nxf4 began the collapse — and the browser-030 self-block, where Bg6
walked the f5 bishop off the fifth rank and handed the h5 queen a capture on
c5 that had been illegal the move before.

So every candidate that survives the destination-square test is pushed, and
the opponent's legal replies are scanned one ply deep:

- **Captures**, priced by the same `_swap_off` the standing sweep uses, run
  over every one of the mover's pieces in the post-move position — which
  catches a defence abandoned, a line opened, and a square vacated alike.
- **Mate**: a reply that is checkmate outranks every material number.
- **Forks** by a knight, queen, or pawn: a reply that lands where the mover
  cannot profitably remove it and hits two pieces — or the king and a piece —
  worth minor-piece value or more, each target priced by the exchange on its
  square, never by face value: a "fork" of a defended piece whose capture
  loses the forker is not a fork.
- A capture that was **not available before the candidate move** (the
  attacking line did not exist) is tagged as a capture the move first allows,
  the mover's own queen included.

The prompt then splits the old safe list in two. A candidate stays safe only
when the worst reply found, less whatever the candidate itself captures,
comes to under a pawn. The rest move to their own bucket, worst reply named
with its cost in centipawns, least-losing entry first, under words that rule
them out absent a concrete tactical answer to the reply shown. A remembered
win (rule 14c) is still never buried: an endorsed candidate the scan reads
against rides the memory-backed line with both facts on it.

A candidate the destination-square test has already priced skips the full
scan — but never the mate half of it. Losing material and being mated are not
on one scale, so a candidate that loses material is swept for mating replies
only (no standing sweep, no fork hunt), and a mate found there outranks the
exchange count, moves the candidate into the punished bucket at mate cost,
and revokes any memory endorsement: no remembered win survives a move that
walks into checkmate. Without that half-sweep a move which drops a pawn AND
allows mate in one is printed as the cheapest line on the board — which is
how browser-066 was lost in twelve moves on 2026-09-17, its 11...e5 labelled
"loses about 1.0 pawns where it lands; memory holds a winning record with
it", the `Qxh7#` behind it never looked for.

## The mate sweep sees two plies, not one

A mate one move further out was read as "safe", and that is how browser-064
was lost on 2026-09-17. At the mover's move 26 all 41 legal moves were
survivable; after the opponent's next move exactly three were, and the other
38 lost to a forced mate in two. All 38 printed "safe", because the first
move of the mate was a check and not a mate, and nothing in the prompt looked
past one ply.

So every candidate that is not already labelled mated in one is swept a
second ply: the opponent's **checking** replies only, each answered by every
legal escape, each escape answered by any mate. A candidate for which some
check leaves no unmated escape is named `reply <check> FORCES CHECKMATE next
move, whatever you answer`, and that verdict behaves exactly as the mate in
one does — it outranks the exchange count, it revokes any memory
endorsement, and it sorts into the punished bucket just behind a mate in one.
The instruction legend says what the label means and that such an option
loses the game however much material it appears to win.

The restriction to checking first moves is what keeps this inside the scan
budget: measured over 120 real positions from the game files (2026-09-17) it
missed none of the 29 mated candidates an unrestricted search found, at 7 ms
per position against 280 ms. The blind spot it buys is a quiet mating net,
which is real and accepted. The whole second-ply sweep also carries its own
deadline, 120 ms across all candidates in a position; past it the sweep stops
and the remaining candidates keep their one-ply verdicts, so an unusually
expensive board degrades in depth and never in speed.

The whole scan
must stay under 150 ms per position (measured 2–9 ms over the three incident
boards, 14–47 candidates each, 2026-08-24); a scan failure is a prompt with
the old two-bucket shape, never a lost move.

## Trades while ahead are counted, not reflexed

When the mover's side is ahead by three pawns of material or more and a
candidate captures a piece — not a pawn — the prompt names each such trade on
its own line and states the material balance that results (the count before
the move, plus the piece taken, less what the exchange on that square gives
back), so simplification is a decision made with the count in view rather
than a reflex. This is the check the user asked for by name on 2026-08-23,
after watching won games thrown in the simplification phase.

## Passed pawns are named

Neither prompt line said anything about pawns about to promote, and the
losses show it: in browser-032 the opponent's f-pawn queened at move 49 and
the g-pawn at move 60, both walking the board unmolested; in browser-031 a
second queen promoted while the mover hunted elsewhere. The prompt now
carries a passed-pawn line, both sides covered: each passed pawn with its
square, how many steps from promoting, and whether any enemy piece or pawn
blocks or guards a square on its path — a clear path is said to be clear,
because "nothing stops it" is the fact that demands a move. The line always
prints ("none" included), for the same reason the standing line does: an
absent line is indistinguishable from the scan having failed.

## A repeated position is named on the option that repeats it

Every verdict the request carries is computed from the position alone, so a
move back into a position the game has already stood in prices exactly as it
did the first time — and the mover, asked the same question, gives the same
answer forever. On 2026-09-17 that drew browser-068: a queen and a rook up
with four times the opponent's clock, the mover answered the rook's checks by
stepping between the same two squares nine times, with two king escapes and a
blocking queen move legal at every one of them, until the fifth repetition
ended the game as a draw.

The request's board is built from a FEN and carries no move stack, so the
game's movetext is replayed from the start and every position counted. Each
option leading back into a counted position carries a clause saying so and
how many times the game has stood there; at the fifth occurrence the clause
says plainly that playing it ends the game drawn. The clause also carries the
consequence, which is a matter of the material count and not of taste: ahead,
a repetition throws the win away and is named as doing so; behind, it saves
the game. The instructions say the rest — never repeat while ahead when a
sound alternative exists, leave the repetition even at a small cost. A
movetext that will not replay, or one that does not land on the position in
hand, produces no clause at all: a missing clause, never a wrong one.

## The quiet-move budget is counted

The one thing measured about her own play that the request never carried. Over
the real games only — the benchmark self-play pool is four times larger and the
effect INVERTS in it, which is how the first version of this finding got
diluted — games decided and reaching move 15 split on a single count: quiet
queen/pawn moves of her own on her move numbers 11-15, where quiet means the
move captures nothing, gives no check, and is not a promotion. At most one in
that window she wins well over half; at two or more it collapses to under a
fifth. Recounted 2026-09-17 and again 2026-09-18, the direction has held across
every recount, and only the magnitudes move.

The sheet is no place for it. The persona file is deliberately empty and the
timed routes reach a decision-only model that emits no prose, so a measured
finding written as advice reaches nothing. It belongs where every other count
already lives: on the option itself. On plies whose full-move number falls in
the window, each option that would be another quiet queen/pawn move carries a
clause naming which one it would be and the stored record at that count — the
count in code, the judgement left to the model, no recommendation and no
suppression, exactly the contract the declined-memory warning has.

The window count is a property of the game, not of the position, so it comes
from replaying the movetext, and a movetext that will not replay onto the
position in hand produces no clause at all. Neither does a pool too small to
quote: below ten decided games in a bucket the clause is silent rather than
citing a record of two games. The tally is rebuilt from the game files at most
once per mover process and keyed on the files themselves, because a hundred
milliseconds of counting must not be spent again on every move of a blitz game.
