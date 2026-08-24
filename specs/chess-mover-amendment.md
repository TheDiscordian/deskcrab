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
against rides the memory-backed line with both facts on it. The whole scan
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
