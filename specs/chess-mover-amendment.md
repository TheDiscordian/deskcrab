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
