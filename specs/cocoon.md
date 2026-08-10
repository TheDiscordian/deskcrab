# Spec: the cocoon — self-change discipline and the dispute turn

## PURPOSE

Two disciplines with one root, written after the morning of 2026-08-10 (the measured record is at
the end). The root: under pressure she reaches for her own machinery — she answers an objection by
shipping a mechanism, and she answers anger by cutting pieces off herself. Both are ways of not
listening, and neither is stopped by a rule she reads, because a rule she reads is a rule she can
reach past when she is sure. So the first discipline is mechanical: in a live turn or wake, what
constitutes her is read-only, and changes go through a builder with a brief. The second is a turn
shape: a message that pushes back on her previous reply is detected, bought at her best attention
instead of her cheapest, and framed by rules that put his report above her model of the machinery.

## CONTRACT

### The cocoon: constituent files are read-only in a live session

1. In a turn or a wake, every write to what CONSTITUTES her MUST be denied mechanically, before
   the tool runs. The constituent set: the repo checkout, the installed library
   (`~/.local/lib/deskcrab`), the `crab` and `crab-debug` binaries, `~/.config/deskcrab` (conf and
   persona sheet), her systemd user units, and `SELF_WATCH_EXTRA`'s equivalents
   (`~/Beatrice/CLAUDE.md`, `~/Beatrice/Library`). Reading any of it is never gated.
2. Builders keep their hands: the job profile carries no gate, and every deny names the road —
   `crab job "<self-contained brief>"`. That asymmetry is the design: the session that is
   mid-conversation describes the change; a builder makes it in a calm hour, at builder strength.
3. Her drawers stay hers. Nothing under `~/.local/share/deskcrab` — wants, journal, engineering
   notes, chess data, memory — is gated, in any profile. The cocoon covers the machinery, not the
   life lived in it.
4. The gate is a PreToolUse hook (`lib/cocoon-gate`) attached by `claude_profile_flags` to the
   turn and wake profiles only, through a settings file generated at flag time so the hook's path
   is the running checkout's, never a path baked into the repo. Edit/Write tool calls are judged
   by realpath — the `~/.local/bin` symlinks into the repo land on the same answer as the repo
   spelled directly. Bash commands are judged by shape: a write-verb (redirection, `sed -i`,
   `tee`, `rm`/`mv`/`cp`/`ln`, `git commit/add/apply/checkout/…`, `systemctl --user
   daemon-reload/enable/disable/…`) naming a constituent path is denied. The heuristic MAY
   overmatch a read that merely names a path in a write-shaped line; the deny message carries the
   road out, so overmatching costs a sentence, while undermatching costs what 2026-08-10 cost.
5. The gate fails open on malformed input — a broken gate must not brick her hands — and stays
   silent on every allowed call: no output, no log, no drag.

### The dispute turn: pushback is detected and changes the turn

6. Every turn's message MUST pass `dispute_detect` before the prompt is built. The detector is
   deterministic — patterns, no model call — because the thing it guards against is exactly a
   model's judgement under pressure. A strong signal alone fires ("you're wrong", "stop arguing",
   "do not gaslight", "I'm reporting", "I never said", "one more time", "taking you offline", and
   kin); weak signals ("no," leading, "wrong", "again", profanity, "I said") need two. Before she
   has said anything there is nothing to dispute, and the detector says no.
7. A dispute turn is bought at strength, not at the voice loop's economy price: effort rises to
   `DISPUTE_EFFORT` (default high) unless the caller already asked for more, and when
   `DISPUTE_MODEL` is set, that model takes the turn. The 2026-08-10 spiral ran entirely on the
   loop's cheapest settings — the turns where being wrong costs the most were the ones bought at
   the lowest price.
8. A dispute turn carries the dispute layer ([prompt-assembly.md](prompt-assembly.md) rule 36b),
   which MUST state, in this spirit and at strength: his report of what he saw or heard IS what
   happened, and is not a claim to evaluate; the rejected theory is dead and may not be restated
   in new words; the artifact he describes is found and read before any cause is named, and "I
   don't know yet" plus one question is a complete answer; no mechanism is substituted for his
   point — no fixes, rules, builders, or commit tables in the turn; no cutting pieces off herself
   — no self-gates, pressure conduct edits, "never again" pledges, shutdown offers, or goodbyes;
   the answer is a few plain sentences in her own voice, no display block unbidden, conceding
   only what is actually true.
9. The frame's overlap with L7's ranking rule is deliberate — the regroup bargain: under pushback
   the ranking rule is the one being broken, so it is restated beside the thing being answered.
10. Detection MUST be visible after the fact: the turn metric records that pushback was detected
    and what the turn was bought at.

## DATA

| Source | Used by | Notes |
|---|---|---|
| `${STATE_PREFIX}-cocoon.json` | turn/wake CLI invocations | generated by `claude_profile_flags`; points at `lib/cocoon-gate` |
| the conversation's last assistant block | `dispute_detect` | a dispute needs something to dispute |
| `DISPUTE_EFFORT`, `DISPUTE_MODEL` | `claude_generate` | conf knobs; default high / unset |

## INTERACTIONS

**The gate may be called by:** the CLI's hook runner, inside turn and wake sessions only.
**The detector may be called by:** `claude_generate`, once per turn, before prompt assembly.
**Neither may:** speak, write to the conversation, book a wake, or block a read.

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
and was never delivered. He took her offline. Every one of those commits was made by the session
being argued with, at the voice loop's cheapest settings; none would have survived rule 1, and the
turn that denied his observation would have been framed by rule 8 instead.

## TESTS

`tests/test_cocoon_gate.sh` — the gate: constituent Edit/Write/Bash shapes denied with the road
named; drawer writes, reads, and read-shaped git allowed; symlinks judged by realpath; malformed
input fails open; the turn and wake profiles carry the settings flag and the job profile does not.
`tests/test_dispute.sh` — the detector on the day's real sentences and on benign kin; the
first-words guard; the layer present on a flagged turn, absent otherwise and absent on wakes; the
escalation visible in the stub CLI's argv (model and effort).
`tests/test_prompt_profiles.sh` — the dispute layer in the order contract and the totals.
