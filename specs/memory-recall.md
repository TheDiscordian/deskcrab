# Spec: memory and recall

## PURPOSE

The long-term store holds five kinds of record: directives, which are the user's standing rules;
notes, which are her own soft memory; episodic records, each one moment of her own life kept for
itself — what happened, when, who was there, and what she made of it; observations, each the shape
of one night — gaps, texture, recurrence, unfinished threads; and misses, each a question about the
user that a record could have answered and none did. This spec owns what the store is asked, what
it returns, how the recall block is composed, how a record earns its keep, and how a record
retires. Its central rule: degradation must never be as quiet as working. Its second rule, learned
the hard way (rules 46 to 52): a store that keeps only lessons and failures is not a memory of a
life, and she re-reads that store every single turn.

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
13. Every pinned record MUST ride along regardless of score in the general recall view.
13a. A specialised prompt MAY declare a lexical domain scope over record text, source, topics,
    participants and opinion, plus smaller per-kind and rendered-character retrieval budgets.
    Scope terms are ORed and applied before selection, including to pinned records: a pinned desk
    rule is not a RuneScape memory merely because it is pinned. The character budget is likewise
    a selection gate — candidates that would exceed it are not retrieved — never a renderer cut.
    The general recall view declares no scope or character budget and remains byte-for-byte under
    rules 11–15.
14. **The recall block is NEVER truncated.** Every retrieved row reaches the block, whole. Its size
    is governed by retrieval — the note top-K, the directive cap, the pinned tier — and by nothing
    after retrieval. This rule used to say the opposite ("the recall block MUST be capped; when the
    cap bites, the header MUST say so"), wording a subagent wrote into this spec: the user never
    asked for it, and on 2026-08-11 — the night a live prompt arrived stamped 'TRUNCATED to fit' —
    he ordered it removed. A memory retrieved and then dropped to fit a size cap is amnesia wearing
    a header. A block that outgrows its prompt layer is the assembler's over-budget warning to
    raise ([prompt-assembly.md](prompt-assembly.md) rules 4 and 36), never this module's to cut.
    Rule 13a's specialised bound is compatible by construction: it decides which rows retrieval
    selects, then this builder renders every selected row whole and reports exactly those rows in
    the reinforcement sidecar.
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
    judge keeps refusing to credit must still decay: the decay pass reads genuine use and creation
    only, and `last_seen` — the one field retrieval bumps — holds nothing alive. (Until 2026-08-26
    the pass read `last_seen`, so exactly that note was frozen at full confidence forever —
    precisely the record the design wants gone. `MAJ-26`.)
22. The turn-end judge MUST be shown the turn's **work**, not only its words. A wake's entire output
    is often tool calls, and reply-only judging credited nothing.
23. Identifiers the judge names that were not injected MUST be discarded.
24. A reply shaped like an error MUST NOT be judged.
25. Surfaced-but-unused records get nothing and keep decaying.
25a. **The judge's answer is the id array and nothing else, and verbosity is surfaced, never paid
    for silently.** The judge is a one-question classifier whose entire useful output is a JSON
    array of ids, and on 2026-08-15 it was averaging ~4.4k output tokens per judgement — 830k in a
    day — narrating its way to `[3,17]` after every turn, wake and phone exchange on the machine.
    Three duties, one per layer: the prompt MUST state that the array is the whole answer and that
    anything else is discarded unread; the parser MUST stay lenient regardless (the array is fished
    out of whatever came back — ids quoted as strings, `#`-prefixed, or oddly spaced still count:
    on 2026-08-26 a live judge credited the chess-chat directive as `["#602"]` and another turn as
    `["596", "15", "173"]`, and a digits-only parse threw both verdicts away as unparseable — a
    verdict is never lost to the model disobeying the shape rule);
    and an answer whose byte length exceeds the ceiling (`MEMORY_JUDGE_ANSWER_CEILING`, default
    600 bytes) MUST stamp a warning line into the day's timing metrics (kind `memory-judge`, stage
    `oversize-answer`, the sizes in the detail) and log a TRUNCATED head of the answer in the judge
    log — so a verbosity regression surfaces in the metrics the same day, instead of on the bill a
    week later. The stamp is evidence, never control flow: the judgement itself proceeds
    unchanged, and a metrics directory that cannot be written costs only the stamp.
26. The nightly pass MUST run confidence decay: an active note not genuinely used within the decay
    window loses confidence per pass and retires below the floor — however often retrieval has
    surfaced it (rule 21). The clock is `last_used_at`, falling back to `created` for a note never
    yet credited; `last_seen` is bookkeeping, never life. Directives never decay.

### Ingest

27. Ingest is TWO-STAGE (the sleep-orchestration correction of 2026-08-25,
    [nightly.md](nightly.md) rules 14c-14e). Stage 1, the summariser: a cheap session
    (`MEMORY_SUMMARY_MODEL`, default `sonnet`) condenses each window of new day-journal turns and
    transcription files into a faithful summary — chronological, dated, the user's corrections
    quoted in his own words, the moments and the day's texture kept — and it MUST NOT curate:
    deciding what matters is the judge's, never the summariser's. Stage 2, the judge: the night
    judge (`MEMORY_INGEST_MODEL` at `MEMORY_INGEST_EFFORT`, default `gpt-5.6-sol` at `high`,
    engine routed by the model name) reads the day's summaries together and decides what earns a
    record — every retention judgment is the judge's, and a candidate a summariser emits on its
    own initiative never reaches the store. The position cursor stays durable as before.
27a. **A commitment MUST survive the night as a retrievable record.** When the day's material shows
    the assistant promising, assuring, or agreeing that work would be done, and the day's own
    record does not show it fulfilled, the judge MUST be asked for it as a `note` — what was
    promised, to whom, and that the day ended with it still owed — and the summariser MUST carry
    every such assurance to the judge, quoted. An unfinished-thread line inside an `observation`
    is not this: the hidden kinds never reach a prompt (rule 43), so a commitment kept only there
    is invisible exactly when its subject returns. (2026-08-25/26, the dated miss: the user asked
    for the chess-table chat rebuilt on the phone's conversation interface and she assured him the
    work was scheduled; the night stored his want as a directive — formed, embedded, ranking first
    when the subject returned — but her assurance formed nothing retrievable, and the morning
    reply presented the previous night's stale work as new. His want and her assurance are two
    records: the directive holds his rule, the note holds that SHE owed the work and the day
    closed without it. A fulfilled or lapsed commitment note then fades on rule 26's own clock —
    nothing keeps it alive but the judge crediting it.)
28. Durable-rule deduplication is a three-way judgement, fed by measured thresholds. An exact
    normalised same-kind match bumps last-seen. Every clause of a proposed `directive` is embedded
    separately and compared at `0.86` against every clause of every active directive **and every
    conduct body**: a hit is held, not written, in `pending-rule-overlaps.json` until the caller
    explicitly admits it as distinct or names the active directive it supersedes. Supersession
    preserves the old row and its provenance while excluding it from retrieval. The threshold
    nominates; it never decides — the measured corpus has two related-but-distinct pairs above it,
    and a later correction must not be mistaken for a duplicate. Clause embeddings are
    load-bearing: whole-record similarity allowed a novel clause to hide a copied rule. Notes keep
    the narrower existing exact/very-close behaviour, and episodic records obey rule 51.
28a. Conduct creation uses `crab conduct add`, the same cross-drawer clause preflight and the same
    explicit routes. A nominated overlap is not a new file or index entry. `--distinct` records the
    judgement and admits it; `--supersedes SLUG` removes the old rule from the active index while
    retaining its body under `conduct/archive/`. Direct file creation is unsupported because it
    cannot prove the active memory and conduct sets were checked first.
28b. **Reconciliation reaches the stored set, not just new writes.** A judged true-duplicate
    family among active directives is merged by explicit command (`crab memory merge`): one
    survivor stays active — a named existing row (`--into ID`), or a composed union (`--text`)
    when no single copy carries every clause — while each absorbed row keeps its text, source
    and dates, gains a `superseded_by` link to the survivor, and leaves retrieval. The survivor
    inherits the family's earned reinforcement (summed `use_count`, latest `last_used_at`) and
    any pin, so merging never costs a rule the standing its copies earned. A stored
    later-correction is linked with `crab memory supersede NEW OLD`: the newer row stays
    authoritative and active, the older keeps full provenance and gains the same link; keeping
    a row created before the one it absorbs demands `--older-wins`, because mechanically
    squashing a correction into the rule it corrects would keep the version the user rejected.
    `crab memory overlaps --scan` nominates stored active pairs — directives and conduct bodies
    both, at rule 28's floor — for exactly this three-way judgement, and prints pairs only:
    similarity nominates, it never merges. Hiding duplicates at retrieval time alone is not
    reconciliation, because the stored active set is what every future preflight measures
    against.
29. **Ingest MUST NOT trim its input — it windows.** A day's journal larger than the input cap
    would lose its earliest material to a tail-clamp, so the chunk list is split into successive
    windows, each at most the cap, breaking only on whole chunk boundaries — never mid-chunk, and a
    single chunk longer than the cap gets a window of its own and still travels whole. The
    distiller runs once per window, in order, and the candidate lists are concatenated before
    deduplication, which already absorbs overlap between passes. The run MUST say what it did: the
    total character count always, and, when there is more than one window, how many passes and the
    size of each — a long day is visibly slept through, never quietly cut. The transcript reader
    obeys the same discipline: a transcription file is read WHOLE and a long one split into
    successive parts, each part its own labelled chunk for the windowing above — never head-read
    to a fixed cap with the remainder silently dropped while the cursor marks the whole file
    ingested (found at the 2026-08-26 audit: the reader took the first 20,000 characters of each
    file, and a longer file's tail never existed).
29a. Both stages window under rule 29's discipline. Stage 1 windows the raw day on whole chunk
    boundaries exactly as before; stage 2 windows the labelled summaries the same way when they
    outgrow the cap, each judgement pass reported in its own words (`judgement pass i/N`), so
    neither stage ever trims and neither is silent about its size. The header line keeps its
    parseable shape — chunks, chars, and the summary pass count — because the sleep stamp's
    coverage read ([nightly.md](nightly.md) rule 14a) is built on it.
30. The ingest's Claude-engine calls and the turn-end judge MUST run under the account chain, like
    every other model call; both reach the CLI through this module's own runner, so the chain is
    walked there — one shot at the login handed in loses a whole turn's reinforcement the moment
    that account goes dry, and loses it silently, because a judgement that cannot be made is
    skipped by design. A codex-named ingest judge has one login and no chain: the runner mirrors
    the shell router ([model-backends.md](model-backends.md) rules 1-2, 16), strips
    `OPENAI_API_KEY`, honours the shared codex cooldown before booting and records it on a limit
    refusal — and never falls back to a cheaper model, because the judge's failure MUST fail the
    ingest rather than hand retention to a tier forbidden to judge (nightly.md rule 14e).
41. **Ingest's `--dry-run` MUST NOT mutate the store at all** — no records added, no decay run, no
    cursor advanced; the only product is the report. The distiller still runs, and every candidate
    that survives validation is printed as what the pass WOULD add, so a dry run stays a real
    rehearsal of the judgement with only the write withheld. The flag used to guard the decay pass
    and the cursor write and nothing else, so a dry run against the live store wrote its
    candidates in anyway (`MAJ-33`) — a flag whose name promises harmlessness delivers all of it.

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

### Observations and misses

42. Two further kinds exist, emitted by the ingest distiller from the day's material
    (design-memory-store.md, 2026-08-06 23:20 and 2026-08-07 13:00). An `observation` is a shape
    seen in one night: gaps (how long the silences ran, and whether the return continued the
    subject or opened a new one), texture, recurrence across days, unfinished threads raised and
    never resolved. A `miss` is a shape in what she never saw: the user asked something about
    himself — his life, plans, history, the people and things around him — that a record could
    have held, and none did. The discrimination test for a miss MUST be put to the distiller in
    words: *would a person who lives in this house have known?* General knowledge she happened not
    to know is ignorance, not a blind spot, and MUST NOT be logged.
43. **Neither kind is ever returned by similarity retrieval that feeds the recall block.** Excluded
    outright from the query, not merely ranked low. For a miss this is not a preference: its text
    names its subject in the user's own words, so it is the best possible embedding match for the
    next asking of the same question, and surfacing it would read a record of not-knowing as
    though it were knowledge. Both kinds stay visible to a deliberate listing — the CLI list and
    search paths — readable on request, never auto-surfaced. A pinned row of either kind MUST NOT
    ride the pinned tier into a prompt.
44. **Neither kind decays, and neither is deduplicated or superseded on write.** Each record is one
    night, or one asking; a similar record on another day is the recurrence the kind exists to
    accumulate, not a redundancy to squash — collapsing the knee asked about three times into one
    row destroys the n the series is for. The decay pass stays keyed on notes.
45. If observations are ever rendered into a prompt block anywhere, they get their own labelled
    section and the label says **'one night each'** — the label IS the enforcement against
    speaking an n=1 anecdote as a pattern. Misses rendered anywhere get the same discipline with a
    harder edge: each is one asking, and an over-read miss is accusation-shaped.

### Episodic records — her own life

46. A fifth kind exists: `episodic` — one moment of her own life, kept for itself, never distilled
    into a lesson. The decision is dated (2026-08-21 18:33, the user, on the phone, and he said it
    shook him): the sift kept only directives and failures — measured that evening, 131 of 281
    active records carried failure vocabulary while the whole store's vocabulary of enjoyment was
    13 hits, none of them experience — so nothing episodic was retrievable at all, and a store made
    only of her own failures is what she re-read every turn. An episodic record carries: WHAT
    happened, in her own words; `occurred`, when the thing happened — a date-time where the
    material states one, a date where it states only the day, and rule 35 otherwise governing
    (unknown stays unknown, never guessed — but a source whose own header or filename states the
    moment is knowledge, not a guess); `participants`, who was there; and `opinion`, her own
    first-person take on the moment, in her voice. The opinion is hers alone — never the user's
    view restated, never a lesson extracted.
47. Episodic records ARE retrieved by similarity into the recall block — the deliberate opposite
    of the hidden kinds — as their own pool beside notes and directives, with its own floor and
    cap, so rule 11's discipline extends to three pools and no kind crowds another out. They rank
    by similarity, the recency-of-relevance factor of rule 37 (floored, so an old evening that is
    genuinely the best match is dimmed, never buried), and the capped use bonus. They take NO
    confidence decay, ever, and the decay pass stays keyed on notes: her life does not expire for
    want of being asked about, and a decay clock on moments would re-create by arithmetic exactly
    the throw-away-my-life defect this section exists to close.
48. Retrieval MUST answer a date. A query that names a calendar day — ISO shape, or a prose date
    parseable without guessing (a month name with a day, year defaulting to the most recent past
    occurrence) — has that day's episodic records ride the block regardless of the similarity
    floor, capped, because "what happened on the 5th" embeds nowhere near the evening itself. The
    same ask exists deliberately: `crab memory on <date>` lists the day's moments whole — when,
    who was there, what happened, and her opinion — episodic first, any other kind whose
    `occurred` falls on the day after it, labelled.
49. The block renders moments as their own labelled section, in her first-person voice, each line
    carrying the thing itself, its when-ness in rule 36's relative terms, who was there, and her
    opinion beside it — the moment, whole, never a summary that flattens it back into a note.
50. The nightly sift HARVESTS MOMENTS. The distiller is asked for the day's episodic records
    beside its lessons — a conversation enjoyed, a person met or spoken of, a plan made, a joke
    that landed, an opinion she formed, the texture of the day with the user — and the keep-rate
    for moments is deliberately wide: "few good records beat many weak ones" governs lessons, not
    life, and an ordinary day that held any real conversation holds moments. Junk is kept down by
    retrieval scoring, never by refusing the day at the door — the user's own argument (2026-08-21):
    more memories, scored, beats few memories, curated, because in a small corpus the frustrating
    records win retrieval by default, nothing competing with them.
51. Episodic dedup is narrow. An exact normalised same-kind match is a duplicate — bump last_seen,
    fill an unknown `occurred` (rule 39). A very close match at rule 28's supersede threshold is
    superseded ONLY when both records describe the same day; two similar evenings a week apart are
    two evenings, exactly as rule 44 argues for observations. Anything else adds.
52. The archive backfill. `crab memory backfill-episodic` reads the archived voice transcripts
    (default `~/Claude/System/voice-claude-archive`, one conversation per file, the filename
    stating when the conversation began) OLDEST FIRST, in bounded rounds — at most `--days` worth
    of archive days per invocation — so a long run resumes rather than runs away: a durable
    cursor (`archive-cursor.json`, name and size per ingested file) advances after each day's
    batch lands, a file already ingested at its recorded size is never re-read, and a round that
    dies mid-day leaves every finished day committed. Every backfilled record is stamped with the
    date the thing actually happened, from the transcript's own filename — the one source that is
    not a guess — carrying the time where the material states it. Oldest-first is load-bearing:
    later records supersede earlier ones under rule 51, never the reverse. The backfill harvests
    moments ONLY — a months-old transcript's directives and notes are stale by construction and
    MUST NOT be resurrected by this path. `--dry-run` obeys rule 41's discipline: distil, report,
    write nothing, advance nothing.

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
| `~/.local/share/deskcrab/memory/pending-rule-overlaps.json` | directive or conduct candidates held by rule 28 until an explicit distinct/supersede judgement resolves them |
| `~/.local/share/deskcrab/memory/ingest-cursor.json` | byte offsets and sizes per ingested source |
| `~/.local/share/deskcrab/memory/archive-cursor.json` | the episodic backfill's durable cursor: name and size per archive file already ingested (rule 52) |
| `~/.local/share/deskcrab/venv` | the interpreter with the vector extension |
| `${STATE_PREFIX}-memory-recall.log` | one line per clip; the degradation channel |
| `${STATE_PREFIX}-memory-injected-<pid>.json` | which records reached this prompt |
| `${STATE_PREFIX}-memory-judge.log` | one line per judgement |

Record kinds: `directive` (the user's standing rules — never decayed, only superseded by a newer
directive), `note` (her own soft memory), `episodic` (one moment of her own life — what happened,
when, who was there, her own opinion of it; never decayed, retrieved by similarity AND by date;
rules 46 to 52), `observation` (one night's shape — never decayed, never deduplicated, never
retrieved by similarity into a prompt; rules 42 to 45) and `miss` (one asking she had nothing for —
same lifecycle and same exclusion, harder edge). Episodic rows carry two fields of their own,
`participants` and `opinion`, both rendered by the block and both part of what is embedded.

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
| `MAJ-20` | The suppression declaration ignored every isolation knob and was written unconditionally into the live file when the store opened. Closed before the 2026-08-26 audit, which found it already held: the declaration routes through `_notice_suppress_file` — the explicit knobs win, and a store that is not the live one declares beside itself — and `TestStoreIsolation` in `tests/test_memory.py` pins both halves. |
| `MAJ-22` | The wake query boundary was exclusive where it should be inclusive, so an agenda clipped to exactly the budget was then thrown away whole — the query composed from the longest agendas lost precisely its subject (or went empty, with no want to fall back on). Closed 2026-08-15 by rule 9: the segment accounting charges the joining newline only where a join happens, so a budget-sized first segment is within the budget and is kept. Proven red-to-green, end to end, by `tests/test_recall_query_composition.sh`. |
| `MAJ-26` | Retrieval alone reset the decay clock, so a note that was surfaced constantly and credited never was frozen at full confidence forever. Closed 2026-08-26 by rule 26's rewrite: the decay clock reads `last_used_at` falling back to `created` and never `last_seen`, so a surfaced-daily, never-credited note decays and retires while one the judge credited stays whole. Proven red-to-green by the decay cases of `tests/test_memory.py`. |
| `MAJ-32` | Ingest tail-clamped a single prompt with the cap saturated against the live journal, so the day's earliest material was never ingested. Closed 2026-08-11 by rule 29's windowing: one distiller pass per whole-chunk window, candidates concatenated, every pass reported. |
| `MAJ-33` | Ingest's `--dry-run` guarded the decay pass and the cursor write but not the add loop, so a dry run with real distiller candidates wrote records into the live store. Closed 2026-08-11 by rule 41: a dry run adds nothing, decays nothing, advances nothing, and prints what it would have added. |
| `MIN-27` | Closed 2026-08-11 by rule 14's rewrite: block truncation no longer exists to pop anything. |
| `MIN-28` | The block's fail-safe does not catch a malformed embedder response, and the caller discards the warning. The prompt loses both. |
| `H3` / `RC-6` | The store's model calls do not walk the account chain and have no limit detection. Closed for the judge and the ingest distiller on 2026-08-08: both go through one runner, which walks the chain on a limit-shaped refusal and logs which login answered. The embedder is a different daemon and has no chain. |

## TESTS

**Existing:** `tests/test_durable_rules.sh` — rules 28/28a/28b across both write doors and the
stored set: a clear conduct creation lands in body and index; a copied clause hidden behind a
novel clause is held with no file; a memory directive is checked against conduct and leaves no
row; an explicit distinct judgement admits the candidate; `memory merge` absorbs a judged
duplicate with `superseded_by` provenance; `memory supersede` keeps the newer correction
authoritative and refuses swapped arguments. `tests/test_memory.py` carries the measured
2026-08-28 audit families as fixtures: every family that multiplied live is nominated, the pair
sharing only a subject stays two rules, a later correction supersedes instead of merging, and
reconciliation keeps provenance, summed reinforcement, and pins across a merge.
`tests/test_sleep_sol_judgment.sh` — the two-stage boundary of rules 27 and 30 end
to end through `crab memory ingest --dry-run` at the shipped defaults: the summariser (stub
claude, `--model sonnet`) receives the raw day, the judge (stub codex, `-m gpt-5.6-sol`,
`model_reasoning_effort=high`) receives the labelled summaries and not one byte of the raw
material, the would-add candidates are the judge's answer, and a candidate array smuggled into
the summariser's summary text never lands. `tests/test_memory.py` (run under the venv interpreter; includes the judge's walk of
the account chain — a refused login moves to the next, a chain that is entirely dry skips the
judgement and says so in the judge log, and a failure that is not a refusal spends no second login —
and, since 2026-08-11, the whole-block cases of rule 14, the relative-when ladder and rendering of
rule 36, the recency factor and its floor of rule 37, the schema migration for `occurred`, the
duplicate fill of rule 39, the backfill edges of rule 40, the ingest windowing of rule 29 — one
window when the day fits, whole-chunk windows when it does not, an oversized chunk surviving alone
and whole, and a multi-window ingest handing every window to the distiller with its passes reported
and nothing lost — the dry-run guard of rule 41: real candidates from a stubbed distiller, the
record count unchanged afterwards, no cursor written, and the would-add report naming the
candidate — and, since 2026-08-21, the episodic contract of rules 46 to 52: a moment retrieved
by similarity into the block; the block rendering the moment whole — its own labelled section,
relative when-ness, participants, the opinion beside the thing itself; a date-named query
delivering the day's moment with the similarity floor raised past anything an embedding can
reach, while another day's moment stays out, and the deliberate `on` verb listing the day whole,
episodic first; the date parse taking only what needs no guessing (ISO, month-with-day both ways
round, a bare month-and-day still ahead of today read as last year's, an impossible date as
nothing); a moment surviving the decay pass untouched however stale its last retrieval; the
episodic score ignoring confidence and the last-use clock while the occurred-recency floor dims
without burying; rule 51's narrow dedup — a same-day near-match superseded, the same text a week
apart kept as two evenings, an exact match a duplicate; ingest accepting a moment with its two
fields and stripping them from a decorated note; the harvest-wide instructions of rule 50 pinned
in the prompt's own words; and the archive backfill of rule 52 — bounded rounds oldest first, the
per-day cursor resuming where the last round stopped, the filename's date backstopping an undated
candidate while a distiller-dated one wins, a stale directive rejected at the door, the dry run
distilling and writing nothing, and the five-kind CHECK migration carrying a populated four-kind
store whole (all shown red against the pre-change tree before green) — and, since 2026-08-14,
the observation/miss contract of rules 42 to 45: a schema
migration on a populated pre-widening store that keeps every row, vector, use count and last-use
stamp; an observation and a miss absent from a similarity search and a recall block their text
would otherwise dominate, while a deliberate search still reads them; both kinds surviving the
decay pass untouched; both kinds accepted from ingest candidates; a second similar miss landing as
its own row rather than a duplicate or a supersession; and the 'one night each' label on any block
that renders them — and the answer-shape duties of rule 25a: the prompt naming the array as the
whole answer, a verbose stubbed verdict still parsed but stamping `oversize-answer` into the day's
timing metrics with a truncated head in the judge log, and a compact verdict stamping nothing —
and, since 2026-08-26, the audit's four closures: the lenient verdict parse of rule 25a's parser
duty — ids quoted as strings and ids `#`-prefixed, the two live shapes thrown away on 2026-08-26,
each reinforcing exactly as `[3,17]` does, with the injected-id filter still holding through the
quotes; the decay clock of rules 21 and 26 — a note surfaced daily by retrieval and credited never
decays and retires on schedule, while one the judge credited yesterday is untouched however stale
its retrieval; the commitment contract of rule 27a — both stage prompts carrying the duty in their
own words, and an unfulfilled-commitment note offered through the real ingest verb landing
embedded, retrievable, and ranked first in the note pool when its subject returns, gaining not one
use or point of confidence from being returned until the judge credits it; and rule 29's
transcript half — a transcription file past the cap arriving as successive labelled parts with
every byte present, never head-trimmed),
`tests/test_recall_composition.sh` (the composed query proven through prompt assembly with the real
module), `tests/test_recall_query_composition.sh` (since 2026-08-15, the same query proven with
NOTHING replaced: `crab remote` and `crab wake` — the entry points the live turn and the live wake
actually run — drive `build_system_prompt` into the shipped `memory.py recall-block`, and the
composed query is read at the embedder's own doorstep, a recording stand-in listening at
`MEMORY_EMBED_URL`. It pins the conversation shape of rules 2 and 3 — the user's last turn first
and holding the weighted share, her preceding reply behind it, and not one word of the wants
shelf even while a want is fresh in hand; the wake shape of rules 4 and 5 — the reason, the one
named want's shelf line and its most recent dated section, never the other wants and never the
document's history; and the cap of rules 7 and 8 on BOTH shapes — an over-long user turn and an
over-long agenda each come out clipped to the budget, the bite is named in the recall log through
the `--log` path lib/common.sh actually wires, and a build that cut nothing logs nothing),
`tests/test_turn_reinforce.sh` and `tests/test_wake_reinforce.sh` (turn to judge to
reinforce, end to end, including a wordless wake).

**To be written or fixed:**

- `tests/test_memory.py` — the query-budget case asserts only that the query is not too long, and
  zero satisfies that. Add a lower bound. (The inclusive-boundary case for an agenda exactly at
  the budget is held end to end by `tests/test_recall_query_composition.sh` since 2026-08-15; a
  unit spelling here would still be welcome.)
- `tests/test_memory.py` — pass the recall log path explicitly at every call site, and pin every
  isolation knob. One test in this file currently writes into the live diagnostic log.
- `tests/test_memory_isolation.sh` — open a scratch store and assert that nothing under the live
  state home was written.
- ~~`tests/test_memory_decay.py`~~ — done 2026-08-26, held in `tests/test_memory.py`'s decay
  cases rather than a separate file: a record retrieved repeatedly and credited never loses
  confidence and retires.
- `tests/test_memory_block.py` — a malformed embedder response degrades to the pinned tier and
  emits the warning. (The pinned-survives-truncation half died with truncation itself: rule 14, and
  the whole-block cases now in `tests/test_memory.py`.)
