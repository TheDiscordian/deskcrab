# Spec: the dispute turn

## PURPOSE

When a message pushes back on her previous reply, detect it, buy the turn at her best attention
instead of her cheapest, and frame it so his report outranks her model of the machinery. This
behavior is independent of filesystem access, maintenance shutdowns, and how implementation work
is performed.

## CONTRACT

### Pushback is detected and changes the turn

6. Every turn's message MUST pass `dispute_detect` before the prompt is built. The detector is
   deterministic — patterns, no model call — because the thing it guards against is exactly a
   model's judgement under pressure. **The guard is ordering-independent**: the detector judges
   the message against her last reply WHEREVER it stands in the transcript
   (`_convo_last_assistant_anywhere`), never against whether her reply is the final block. Both
   turn paths append his message to the conversation before generation runs, so in production
   her reply is never the final block — the original final-block guard meant the detector fired
   on no production turn, ever, while its tests fed it transcripts no turn ever sees. Before she
   has said anything at all there is still nothing to dispute, and the detector says no.
6a. The patterns are four classes, because the detector's two consumers pay different prices
   for a false positive. STRONG is the only class that supersedes (rule 6b), and it is
   deliberately narrow: nothing in it has a benign reading when aimed at her rejecting the
   reply in flight. Direct contradiction ("you're wrong", "stop arguing", "stop talking",
   "that's not / that is not / that isn't / that wasn't — it, what…, right, true, the bug, the
   problem, the issue, the answer, the point"); what she did to his words ("not what I
   said/meant/asked", "you misunderstood", "you misheard", "you didn't answer/listen/read/
   hear"); the argument's own escalation ("do not gaslight/lie/argue", "gaslight", "you keep
   lying", "one more fucking time"); profanity aimed at her ("fuck you", "fuck off", "your
   fucking problem/issue", "the fuck is/are wrong/you"); him locating the artifact himself
   ("it was in a quiet block"); and a correction phrased as a question ("why did you X when I
   asked/said/told Y"). FIRM fires the dispute frame alone and supersedes nothing: the shapes
   that are usually pushback but each carry an innocent reading — "your problem/issue" without
   profanity ("is your issue resolved now?"), "I never said/asked" ("I never asked her out"),
   "I didn't say/ask/tell" ("I didn't tell her yet"), "you lied" ("you lied to me in poker
   last night lol"), "what is wrong with you" ("haha what is wrong with you"), "taking you
   offline"/"turning you off" ("I'm turning you off for the night"), "stop assuming/repeating"
   ("please stop assuming the worst about my brother"), "shut up" ("tell the linter to shut
   up"), "not listening" ("he's not listening to reason lately"), the "listen to me" demand
   (never the invitation — "listen to me play this" does not fire at all), and "I'm reporting"
   beside something broken (never "I'm reporting that it works"). Over-firing FIRM is the
   tolerable cost: it buys a stronger, framed turn and kills nothing. SOFT fires the dispute
   turn too and supersedes nothing: a bare "no."/"no," with a restatement behind it is a real
   correction shape, but it is also the shape of "No, that's fine". WEAK signals need two and
   also never supersede: a leading "no", "wrong", "again", "I said", and profanity only when it
   is aimed ("the fuck", "fuck you", "you're fucking…") — profanity as colour ("that was
   fucking great") counts nothing. The benign kin the first cut tripped on are excluded by
   construction and held by test: "one more time" alone, "run it one more time", lone
   profanity, "no worries".
6b. Superseding a turn still in flight ([turn-pipeline.md](turn-pipeline.md) rule 15c) requires
   the STRONG class, and STRONG must stay narrow enough to deserve it: a superseded reply is
   silently and unrecoverably never spoken — no brake on any channel can un-kill it — so
   nothing that could be a benign message may EVER supersede. The dispute frame and the
   escalation may ride on FIRM, SOFT, or two WEAK — over-applying them costs a stronger turn,
   which is a price the design accepts.
7. A dispute turn is bought at strength, not at the voice loop's economy price: effort rises to
   `DISPUTE_EFFORT` (default high) unless the caller already asked for more, and when
   `DISPUTE_MODEL` is set, that model takes the turn. The 2026-08-10 spiral ran entirely on the
   loop's cheapest settings — the turns where being wrong costs the most were the ones bought at
   the lowest price. Strength never costs the turn its life: when every account refuses at the
   raised model, the walk re-runs once at the ordinary model with the frame intact
   ([account-fallback.md](account-fallback.md) rule 10a) — on 2026-08-15 a dispute turn died
   over the premium model's per-account allowance while the ordinary model worked on the same
   logins.
8. A dispute turn carries the dispute layer ([prompt-assembly.md](prompt-assembly.md) rule 36b),
   which MUST state, in this spirit and at strength: his report of what he saw or heard IS what
   happened, and is not a claim to evaluate; the rejected theory is dead and may not be restated
   in new words; the artifact he describes is found and read before any cause is named, and "I
   don't know yet" plus one question is a complete answer; no mechanism is substituted for his
   point — no fixes, rules, builders, or commit tables in the turn; no cutting pieces off herself
   — no self-gates, pressure conduct edits, "never again" pledges, shutdown offers, or goodbyes;
   the answer is a few plain sentences, no display block unbidden, conceding only what is
   actually true. The voice demand — his most-repeated — MUST be stated as an observable, never
   as "your own voice": the frame names the register itself (the coding agent's report cadence,
   the machinery vocabulary, the stock phrases her claudism list exists to catch) and points at
   the pre-speech mirror — a line the mirror hands back during this turn is that failure caught
   in the act, to be rewritten as speech, never defended and never swapped for a synonym from
   the same register. "Answer in your own voice" was the first cut's wording, and it was
   unfalsifiable: it covered the demand with nothing she could check.
8a. When the regroup layer and the dispute layer fire in the same prompt, the dispute layer MUST
   reconcile them, because they contradict: regroup says fold in what another session is saying
   and carry it forward, and the folded-in words can BE the rejected theory. The dispute layer —
   which sits below regroup in the order and wins — states that anything in the other reply
   resting on a theory this message rejects is dead there too: she folds in only what survives
   what he just said. The reconciliation sentence is emitted only when both layers are present
   (rule 29 of prompt-assembly: nothing points at a block that is not there).
9. The frame's overlap with L7's ranking rule is deliberate — the regroup bargain: under pushback
   the ranking rule is the one being broken, so it is restated beside the thing being answered.
10. Detection MUST be visible after the fact: the turn metric records that pushback was detected
    and what the turn was bought at.

## DATA

| Source | Used by | Notes |
|---|---|---|
| her last reply, wherever it stands (`_convo_last_assistant_anywhere`) | `dispute_detect` | a dispute needs something to dispute; ordering-independent (rule 6) |
| `DISPUTE_EFFORT`, `DISPUTE_MODEL` | `claude_generate` | conf knobs; default high / unset |
| `DISPUTE_SUPERSEDES` | `_turn_order_is_pushback` | set by the detector on STRONG only (rule 6b) |

## INTERACTIONS

**The detector may be called by:** `claude_generate`, once per turn, before prompt assembly, and
`_turn_order_is_pushback` for the supersede decision.
**It may not:** speak, write to the conversation, or book a wake.

## EVIDENCE — 2026-08-10

The morning the two disciplines were written from. He made the same behavioural demands over and
over — stop the Claude-voice (ten times), answer what I actually said (eight), stop editing
yourself under pressure (six), stop lying (five), stop repeating pledges (four) — while she ran
the cycle: concede in sentence one, substitute a mechanism for the observation, ship it with a
commit table, meet the rejection, pick a new mechanism. In the terminal fight (12:26–12:34) his
report was that a banned word had reached his screen inside a `(quiet)` block; he located the bug
himself — "it was in a quiet block", "nothing to do with the speech gate" — while she produced
five wrong theories in eight turns, two of them flat denials of what he had seen, and shipped six
commits to her own speech machinery mid-argument. The correct answer existed in a parallel session
and was never delivered. He took her offline. The turn that denied his observation would have been
framed by rule 8.

## TESTS

`tests/test_dispute.sh` — the detector on the day's real sentences and on benign kin, judged on a
production-shaped transcript (his message appended last, as both turn paths leave it); the
first-words guard; the strong/soft/weak classes and the supersede line; the layer present on a
flagged turn, absent otherwise and absent on wakes; the regroup reconciliation present only when
both layers are; the escalation visible in the stub CLI's argv (model and effort).
`tests/test_prompt_profiles.sh` — the dispute layer in the order contract and the totals.
