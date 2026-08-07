# Spec: memory and recall

## PURPOSE

The long-term store holds two kinds of record: directives, which are the user's standing rules, and
notes, which are her own soft memory. This spec owns what the store is asked, what it returns, how
the recall block is composed, how a record earns its keep, and how a record retires. Its central
rule: degradation must never be as quiet as working.

## CONTRACT

### Composition — what the store is asked

1. What the store is asked MUST fork on what the session is. In conversation the subject is the
   conversation; on a wake the subject is the agenda.
2. A conversation query MUST be composed from the last user block first, holding the larger share of
   the budget, with her immediately preceding reply behind it as context. Headers are stripped, the
   display channel is dropped, and inter-block wake markers are dropped.
3. A conversation query MUST NOT contain the wants shelf. Memories have nothing to do with wants
   unless a want is actively being pursued.
4. A wake query MUST be composed from the reason, plus the one want being worked if it can be named:
   that want's shelf topic and its most recent dated section only.
5. A wake query MUST NOT be padded with unrelated shelf topics when the reason names no want. A
   reason with nothing to attach to stands alone.
6. Block headers MUST be matched with the timestamp optional, or every archive and every pre-stamp
   transcript composes an empty query and looks exactly like a quiet conversation.
7. The query budget MUST be under the embedder's limit, and the embedder's limit governs. The
   characters-per-token estimate MUST be low on purpose, so the ceiling is wrong in the safe
   direction.
8. Clipping MUST NOT be silent. Every bite taken is recorded, and one line naming what was cut is
   written to the recall log.
9. The clipping boundary MUST be inclusive of the budget. A segment exactly the size of the budget
   is within the budget; rejecting it composes an empty query from a long agenda.
10. The embedder call MUST clamp to the character cap, retry a length refusal at half the length, and
    raise an error carrying the daemon's own response body. The generic transport message is exactly
    how a length limit once passed for a dead embedder.

### Retrieval

11. Notes and directives MUST be queried as two pools with different floors, so her own notes can
    never crowd the user's rules out.
12. Notes are ranked by similarity, confidence, decay, and a capped use bonus. Directives are ranked
    by raw similarity and are never decayed or boosted.
13. Every pinned record MUST ride along regardless of score.
14. The recall block MUST be capped. When the cap bites, the header MUST say so.
15. **Truncation MUST NOT drop a pinned record.** Pinned records are guaranteed retrieved, so
    dropping them first when the block is over budget contradicts the guarantee.
16. The block MUST be written in her own first-person voice.
17. The block MUST be fail-safe by contract: an empty store adds nothing, a dead embedder degrades to
    the pinned tier with a loud warning, and neither ever breaks a prompt build.
18. The fail-safe MUST catch every error a malformed embedder response can raise, not only transport
    errors. A parse error currently escapes, and the caller discards the warning, so the prompt loses
    both the block and the promised warning.
19. The block builder MUST leave a sidecar naming the records that actually reached the prompt, with
    truncated-away notes excluded.

### Reinforcement and decay

20. Reinforcement MUST be written only when a record was genuinely used in a turn. Retrieval alone
    bumps only the last-seen field.
21. **Retrieval alone MUST NOT reset the decay clock.** A note the retriever keeps surfacing and the
    judge keeps refusing to credit must still decay. Today it is frozen at full confidence forever —
    precisely the record the design wants gone.
22. The turn-end judge MUST be shown the turn's **work**, not only its words. A wake's entire output
    is often tool calls, and reply-only judging credited nothing.
23. Identifiers the judge names that were not injected MUST be discarded.
24. A reply shaped like an error MUST NOT be judged.
25. Surfaced-but-unused records get nothing and keep decaying.
26. The nightly pass MUST run confidence decay: an active note neither retrieved nor used within the
    decay window loses confidence per pass and retires below the floor. Directives never decay.

### Ingest

27. Ingest MUST distil new day-journal turns and transcription files through a cheap session into
    candidate records, tracking its position with a durable cursor.
28. Deduplication MUST be by measured thresholds: an exact normalised match of the same kind bumps
    last-seen; a very close match with different text supersedes, newer winning, with the old record
    left readable and excluded from retrieval; anything below simply adds.
29. **Ingest MUST NOT tail-clamp its input.** A day's journal larger than the input cap means the
    day's earliest material is never ingested at all. Chunk it.
30. The ingest session MUST run under the account chain, like every other model call.

### Isolation

31. Every path in the store MUST honour every instance redirect: the state prefix, the memory
    directory, and the state home. A component that derives a path from one variable only writes
    into the live instance from a scratch one.
32. The suppression declaration the store writes MUST honour those redirects too. It is written
    unconditionally when the store is opened, so a test that opens a scratch store writes into the
    live declaration file.
33. The recall log path MUST be explicit at every call site. A default that points at the live log
    means a test poisons the one diagnostic channel this subsystem has.

## DATA

| Path | Role |
|---|---|
| `~/.local/share/deskcrab/memory/memory.db` | the store; override with the memory directory variable |
| `~/.local/share/deskcrab/memory/ingest-cursor.json` | byte offsets and sizes per ingested source |
| `~/.local/share/deskcrab/venv` | the interpreter with the vector extension |
| `${STATE_PREFIX}-memory-recall.log` | one line per clip; the degradation channel |
| `${STATE_PREFIX}-memory-injected-<pid>.json` | which records reached this prompt |
| `${STATE_PREFIX}-memory-judge.log` | one line per judgement |

Record kinds: `directive` (the user's standing rules — never decayed, only superseded by a newer
directive) and `note` (her own soft memory).

## INTERACTIONS

**Memory may call:** the local embedding daemon, a cheap model session for ingest and judging (via
the account chain), and the write-declaration helper.

**Memory may be called by:** prompt assembly (the recall block), the turn and wake paths (the
judge), `crab memory`, and the nightly sleep.

**Memory must never:** speak, book a wake, or write to the conversation.

## VERIFIED-CORRECT RULES

- **Two pools with different floors, queried separately.** Her own notes can never crowd the user's
  rules out.
- **Directives are never decayed and never boosted.** They are owed, not earned.
- **The recall block is fail-safe by contract.** A broken memory must never break a prompt build.
- **Reinforcement is written on use, never on retrieval.**
- **The judge is shown the work as well as the words.** Measured on one wake: reply-only judging
  credited one record; judging on the trace credited three.
- **What the prompt will take and what the embedder will take are different numbers, and the small
  one governs.** The daemon refuses an over-long input rather than truncating it, and the ceiling is
  a property of the text as much as of the model.
- **The query is composed for the session it is in.** An earlier version asked the store about her
  wants shelf while the user was talking about his own business, every turn, all day.
- **A want document is asked about by its most recent dated section, not its whole text.** These
  documents grow by appending, and the clamp bites from the front — a whole-document query is
  silently a query about the oldest material.
- **The deduplication thresholds are measured, not taken from the design note.** A one-word factual
  change embeds very close, so a looser duplicate threshold would keep a stale fact active; related
  but distinct rules land in a band where an automatic supersede ate two real directives on the
  first live ingest.
- **The composition test loads the real module and calls the real composer**, so a green run is a
  statement about shipped code rather than a re-implementation.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `MAJ-20` | The suppression declaration ignores every isolation knob and is written unconditionally when the store opens. Scratch store paths are in the live declaration file. |
| `MAJ-22` | The wake query boundary is exclusive where it should be inclusive, so an agenda exactly at the budget composes an empty query. Latent today — live agendas are far under the budget — but it is the boundary the first long agenda hits, and the belief that it was firing was itself the harm. |
| `MAJ-26` | Retrieval alone resets the decay clock, so a note that is surfaced constantly and credited never is frozen at full confidence forever. |
| `MAJ-32` | Ingest tail-clamps a single prompt, and the cap is saturated against the current journal, so the day's earliest material is never ingested. |
| `MIN-27` | Block truncation pops from the tail, so a pinned record is the first thing dropped. |
| `MIN-28` | The block's fail-safe does not catch a malformed embedder response, and the caller discards the warning. The prompt loses both. |
| `H3` / `RC-6` | The store's model calls do not walk the account chain and have no limit detection. |

## TESTS

**Existing:** `tests/test_memory.py` (65 cases, run under the venv interpreter),
`tests/test_recall_composition.sh` (the composed query proven through prompt assembly with the real
module), `tests/test_turn_reinforce.sh` and `tests/test_wake_reinforce.sh` (turn to judge to
reinforce, end to end, including a wordless wake).

**To be written or fixed:**

- `tests/test_memory.py` — the query-budget case asserts only that the query is not too long, and
  zero satisfies that. Add a lower bound. Add the inclusive-boundary case for an agenda exactly at
  the budget.
- `tests/test_memory.py` — pass the recall log path explicitly at every call site, and pin every
  isolation knob. One test in this file currently writes into the live diagnostic log.
- `tests/test_memory_isolation.sh` — open a scratch store and assert that nothing under the live
  state home was written.
- `tests/test_memory_decay.py` — a record retrieved repeatedly and credited never must lose
  confidence and retire.
- `tests/test_memory_block.py` — a pinned record survives truncation; a malformed embedder response
  degrades to the pinned tier and emits the warning.
- `tests/test_memory_ingest.py` — a journal larger than the input cap is ingested in full.
