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
12. Notes are ranked by similarity, confidence, decay, a capped use bonus, and the
    recency-of-relevance factor of rule 37. Directives are ranked by raw similarity and are never
    decayed or boosted.
13. Every pinned record MUST ride along regardless of score.
14. **The recall block is NEVER truncated.** Every retrieved row reaches the block, whole. Its size
    is governed by retrieval — the note top-K, the directive cap, the pinned tier — and by nothing
    after retrieval. This rule used to say the opposite ("the recall block MUST be capped; when the
    cap bites, the header MUST say so"), wording a subagent wrote into this spec: the user never
    asked for it, and on 2026-08-11 — the night a live prompt arrived stamped 'TRUNCATED to fit' —
    he ordered it removed. A memory retrieved and then dropped to fit a size cap is amnesia wearing
    a header. A block that outgrows its prompt layer is the assembler's over-budget warning to
    raise ([prompt-assembly.md](prompt-assembly.md) rules 4 and 36), never this module's to cut.
15. Because nothing is dropped, no drop order exists to get wrong. (This rule once guarded pinned
    records against being truncated first; with rule 14 as it now stands there is nothing to guard
    against, and the guarantee — every pinned record reaches the prompt — holds trivially.)
16. The block MUST be written in her own first-person voice.
17. The block MUST be fail-safe by contract: an empty store adds nothing, a dead embedder degrades to
    the pinned tier with a loud warning, and neither ever breaks a prompt build.
18. The fail-safe MUST catch every error a malformed embedder response can raise, not only transport
    errors. A parse error currently escapes, and the caller discards the warning, so the prompt loses
    both the block and the promised warning.
19. The block builder MUST leave a sidecar naming the records that actually reached the prompt —
    which, with rule 14, is every row the block was handed, by construction.

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
30. The ingest session and the turn-end judge MUST run under the account chain, like every other
    model call. Both reach the CLI through this module's own runner, so the chain is walked there;
    one shot at the login handed in loses a whole turn's reinforcement the moment that account goes
    dry, and loses it silently, because a judgement that cannot be made is skipped by design.

### Temporal grounding

34. Every record MAY carry `occurred`: when the thing it DESCRIBES happened, distinct from
    `created`, when the record was written about it. Before this existed she could retrieve that a
    thing was true but not when it happened, how long it mattered, or that it stopped mattering —
    a memory with no when-ness is a fact floating free of her own history.
35. An unknown `occurred` stays NULL. It MUST NOT be guessed — not from the ingest date, not from
    the creation stamp, not from anything. Unknown rendered as unknown beats a confident wrong date.
36. The recall block MUST render each row's when-ness in relative human terms ('yesterday', 'three
    days ago', 'about two months ago'), never as a bare timestamp — a stamp retrieved into a prompt
    is arithmetic she has to do while answering, and mostly does not. A known `occurred` speaks for
    the thing itself; a row without one has its write date speak, named as exactly that ('recorded
    three days ago') rather than passed off as the event's. A directive with a known `occurred`
    reads 'standing since …', because a directive is not an event that faded — it is a rule with a
    start.
37. Note scoring MUST factor recency-of-relevance: a note whose `occurred` is recent outranks an
    equally-similar note about something long past, by a factor floored well above zero, so age
    alone can never bury a note that is genuinely the best match. A note with no `occurred` takes
    no factor at all. **Directives take none of this ever** — the user's standing rules do not
    decay, do not age out, and are ranked by raw similarity exactly as rule 12 has always said.
38. Ingest MUST ask the distiller for `occurred` on records that describe something that happened,
    dated from the material's own headers, and MUST accept its absence: rule 35's never-guess
    applies to the model too, and an unparseable date is dropped, not stored broken.
39. A duplicate arriving with a date MUST fill an existing record's unknown `occurred` — new
    knowledge about an old record — and MUST NOT overwrite one already known.
40. Rows from before this contract are backfilled once, from the only source that is not a guess:
    the record's own text naming exactly one calendar date (ISO shape only). Two dates is
    ambiguous and left unknown; a future date is a schedule, not an event, and left unknown; no
    date stays unknown, and rule 36's 'recorded …' fallback still gives such a row honest
    when-ness. The backfill is `crab memory backfill-occurred`, idempotent, with `--dry-run`.

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

Temporal fields, distinct on purpose: `created` (when the record was written), `last_seen` (when
retrieval last surfaced it), `last_used_at` (when the judge last credited it), and `occurred` (when
the thing it describes happened — NULL when unknown, and never guessed; rules 34 to 40).

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
| `MIN-27` | Closed 2026-08-11 by rule 14's rewrite: block truncation no longer exists to pop anything. |
| `MIN-28` | The block's fail-safe does not catch a malformed embedder response, and the caller discards the warning. The prompt loses both. |
| `H3` / `RC-6` | The store's model calls do not walk the account chain and have no limit detection. Closed for the judge and the ingest distiller on 2026-08-08: both go through one runner, which walks the chain on a limit-shaped refusal and logs which login answered. The embedder is a different daemon and has no chain. |

## TESTS

**Existing:** `tests/test_memory.py` (run under the venv interpreter; includes the judge's walk of
the account chain — a refused login moves to the next, a chain that is entirely dry skips the
judgement and says so in the judge log, and a failure that is not a refusal spends no second login —
and, since 2026-08-11, the whole-block cases of rule 14, the relative-when ladder and rendering of
rule 36, the recency factor and its floor of rule 37, the schema migration for `occurred`, the
duplicate fill of rule 39, and the backfill edges of rule 40),
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
- `tests/test_memory_block.py` — a malformed embedder response degrades to the pinned tier and
  emits the warning. (The pinned-survives-truncation half died with truncation itself: rule 14, and
  the whole-block cases now in `tests/test_memory.py`.)
- `tests/test_memory_ingest.py` — a journal larger than the input cap is ingested in full.
