# Spec: engineering records

## PURPOSE

An engineering note used to be appended prose: undated in effect, stateless by construction, and
louder than memory because it sat in the prompt plainly while memory had to earn its way in by
similarity. Twice on 2026-08-10 a pre-settlement worry, still written as present-tense fact, was
announced as a live code flaw that did not exist. The fix is not better retrieval — it is the state
of the written record. A thread is a RECORD with fields: when it opened, when a hand last touched
it, whether it is open, settled, or dead, and what settled it. A settled thing must read as settled
at a glance, so it can never be quoted back as a live worry. Design settled by the user and the
assistant together on 2026-08-11; the session is recorded in
`~/.local/share/deskcrab/engineering/memory-as-records.md`.

Since 2026-08-25 the record machinery in `lib/eng` is also the SPINE of the wants drawer
([wants.md](wants.md)): one parser, one atomic writer, one write declaration, one search,
parameterized by kind. Nothing in this contract changes for kind `eng` — it is the default, and
`crab eng` passes no kind at all.

## CONTRACT

### The record

1. One file per thread: `~/.local/share/deskcrab/engineering/records/<slug>.md`. The directory is
   overridable as `DESKCRAB_ENG_DIR`, and every caller in the repo passes it explicitly from the
   instance's own data home, so a scratch instance's records stay in the scratch instance.
2. The file opens with YAML frontmatter carrying exactly these fields: `id` (the slug), `title`,
   `opened` (ISO local datetime), `last_touched` (ISO local datetime), `state`
   (`open` | `review` | `settled` | `dead`), `settled_at`, `settled_by` (who or what settled it),
   and `summary` (one line). `settled_at` and `settled_by` are empty while the record is open.
   `review` (kind `eng` only — the wants drawer keeps its own states) is an open thread whose
   latest work has been SUBMITTED for the completion review of rules 16–16d: live, not resolved.
3. The body below the frontmatter is free prose, newest entries first, each entry headed with its
   own ISO datetime. An undated migrated entry is headed `(undated)` rather than given an invented
   date.
4. A state transition happens ONLY through the tool, never by hand-editing the file, so
   `last_touched` can never drift from the truth of when a hand last moved the record. The tool is
   the one writer of frontmatter.

### The tool — `crab eng`

5. `crab eng new <title>` creates a record: state `open`, `opened` and `last_touched` now, the slug
   derived from the title, collisions resolved with a numeric suffix rather than an overwrite. It
   prints the id.
6. `crab eng list [--state open|settled|dead|all]` lists records one line each — open ones first,
   most recently touched first, each with its dates; settled and dead ones as their one-line
   outcome. `crab eng show <id>` prints the whole record.
7. `crab eng touch <id> <note>` prepends a dated entry to the body AND bumps `last_touched` in the
   same write. There is no way to add an entry without moving the date — that pairing is the whole
   mechanism the job hook trusts.
8. `crab eng settle <id> <what-settled-it>` sets state `settled`, stamps `settled_at`, records the
   argument as `settled_by`, adds a dated entry, and bumps `last_touched`. `crab eng kill <id>
   [reason]` does the same with state `dead`. Neither deletes anything.
9. `crab eng search <words>` matches case-insensitively across every record's frontmatter and body
   and names the records it hit. `crab eng field <id> <key>` prints one frontmatter value;
   `crab eng touched-since <id> <epoch>` exits 0 exactly when the record's `last_touched` is newer
   than the epoch — the comparison lives here, in the one place that parses the format, not in any
   caller.
10. An id the tool does not know is an error, never a silent no-op and never a fresh file.

10a. The records directory is part of the self-change watch set, so every code path of the tool
    that creates or modifies a file there — `new`, `touch`, `settle`, `kill`, `migrate`, all of
    them funnelling through the one atomic writer — MUST declare the write FIRST, through the
    write-declaration mechanism the watcher honours (`crab touching`, i.e. `touch_suppress` in
    `lib/common.sh`; [nightly.md](nightly.md) rules 25–27), covering every path actually written:
    the record file and the temporary it is atomically replaced from. The watcher is never
    special-cased by directory name — the writing hand declares itself, so a genuinely
    out-of-band edit to the very same file still surfaces. The declaration is best-effort: a
    missing or failing declaration must not cost the record write itself. Without this, a
    `crab eng touch` made from a live wake at 2026-08-11 11:22 was reported back one minute
    later as an intruder's change to her own files.

### The prompt

11. The engineering drawer reaches the speaking prompts (turn and wake) through `lib/eng prompt`,
    rendered into the shelves layer as a bounded index. Records in `review` lead the live section,
    followed by the most recently touched OPEN records. The turn profile shows at most 12 live
    records and the wake profile at most 20; `DESKCRAB_ENG_PROMPT_MAX_OPEN_TURN` and
    `DESKCRAB_ENG_PROMPT_MAX_OPEN` override those limits. Any omitted live records are counted
    beside `crab eng list --state all` and `crab eng search <words>`, so the complete drawer is
    always reachable without being reread on every invocation. Each rendered record line is
    bounded to 360 bytes by default (`DESKCRAB_ENG_PROMPT_LINE_BYTES`) and retains its id, state,
    and dates; `crab eng show <id>` retains the complete title, outcome, and body. SETTLED and DEAD
    records never contribute body prose, so resolved worries cannot return as present-tense facts.
    The wake profile shows the recent closures selected by rule 11a, while `--compact` (the turn
    profile) shows only the closure count. The rendering states plainly that settled entries are
    history, not live concerns.
    Detail in [prompt-assembly.md](prompt-assembly.md) rule 21a, which owns the layer.
11a. The settled section carries only RECENT closures. A closure renders when its `settled_at`
    falls inside a window (default 7 days, `DESKCRAB_ENG_PROMPT_WINDOW_DAYS`); whatever the window
    says, the most recent closures always render up to a floor (default 5,
    `DESKCRAB_ENG_PROMPT_MIN_CLOSED`) and never past a cap (default 10,
    `DESKCRAB_ENG_PROMPT_MAX_CLOSED`), the cap binding last. An older closure is not rendered in
    the block at all — it stays on disk, reachable exactly as before through
    `crab eng list --state all`, `crab eng show <id>` and `crab eng search` — and whenever
    anything is withheld the section's preamble says how many and names those doors, so the block
    never reads as though the history is gone. OPEN and `review` records remain live regardless of
    age; the prompt index may omit them only behind the counted retrieval pointer in rule 11.
    This is not a cut in the sense [prompt-assembly.md](prompt-assembly.md) rule 4 forbids. Rule 4
    binds the ASSEMBLER, which must carry every layer it is handed whole; this is the drawer
    deciding what it hands over — the same judgement that already renders a settled record as one
    outcome line instead of its body prose. The reason closures appear at all — a resolved worry
    must read as resolved rather than as a quotable present-tense fact — applies to threads recent
    enough that she might still be carrying them as live. A thread settled a month ago is not a
    live worry that needs disarming. Measured 2026-08-14: settling 37 threads and killing 3 in one
    evening GREW the block from about 15.3 KB to about 20.1 KB, because an outcome line is longer
    than the two dated lines it replaces and, before this rule, nothing ever left.
12. The renderer is fail-safe: an empty or missing drawer contributes nothing, an unparseable
    record is skipped, a bad aging knob falls back to its default, and no failure of the renderer
    may break a prompt build.

### The job hook

13. `crab job --record <id>` ties a dispatched builder to the record it came from. The runner MUST
    refuse to mark such a job successful unless the record's `last_touched` is newer than the job's
    dispatch time — the builder updated the record it came from, or the job is `failed` with a
    reason naming the record. The rules live in [jobs.md](jobs.md) rules 27–30, which own the job
    lifecycle. This pairs with the standing rule that a builder verifies with a real grep or test
    before claiming done: the record entry is where that verification is written down.

### Migration

14. The pre-records prose — the `## ` entries of `engineering.md` and the
    `- [file](file) — description` bullets of `engineering/INDEX.md` — is converted once by
    `crab eng migrate <file>`: one record per entry, `opened` and `last_touched` taken from the
    entry's own heading or description where it names a date, left blank rather than guessed where
    it does not. An index bullet's record keeps the linked file's own name as id and title and
    points back at the file, whose prose stays where it is. State is `open` unless the entry
    itself marks it settled or closed; prose is never interpreted. The migration is idempotent
    (an existing slug is skipped, never overwritten) and the source files are left in place as a
    read-only archive.

### The ending gate

15. A record must not END at "I cannot do this", nor at a chore for the user. The origin
    (2026-08-25 04:38, thread `my-output-can-end-in-a-chore-for-him-and-a-recor`): the
    stale-tidy-unit record was closed for the night with two command lines for the user to run —
    one of them, "Also unset: TIDY_CLAIMS_ROOTS", a statement phrased so it READ as an instruction
    — and he woke at 09:51 to a chore his own machine could have run. So `crab eng touch` (kind
    `eng` only — settle and kill are decisions about a thread, and killing a thread as impossible
    is a decision, not an abdication) holds the gate: when the note's LAST non-blank line is part
    of a chore aimed at the user, or its closing clause is inability, and the note attaches no job
    id, the tool dispatches a builder against this record through the job door
    (`crab job --record <id>`, [jobs.md](jobs.md) rules 7b and 27–30 — the door's own policy
    stands whole, so while he is awake and a shelf exists the brief QUEUES, which still yields the
    id) and appends the job id to the very entry, in the same write. The judgement is
    `lib/chore-scan` — ONE detector, shared with the delivery gate of
    [turn-pipeline.md](turn-pipeline.md) rule 16c, judged on how the words READ, because how they
    read is the harm. Only the ENDING is judged: inability narrated mid-note on the way to an
    outcome is history, exactly as a wait narrated mid-report is to [jobs.md](jobs.md) rule 39.
15a. Exactly once. A note that already carries a job id passes untouched, and a record that a
    `queued`, `dispatched` or `running` job already stands against gets THAT id named on the entry
    instead of a second builder — which is also what ends the chain: the builder such a job runs
    can write its own inability onto the record without dispatching a successor for itself.
15b. The gate's own write must not satisfy the job hook. Attaching the id touches the record
    AFTER dispatch, which is exactly the shape rule 13's comparison trusts — so the attach write's
    epoch is stamped on the job sidecar as `record_attached_epoch`, and the runner's comparison
    floors on it at check time ([jobs.md](jobs.md) rule 27). The builder still owes the record its
    own entry; the gate's attach can never stand in for it.
15c. The write is never lost to the gate. A dispatch the door refuses (the block marker, a broken
    substitution shape, no door at all) is written onto the entry itself, named, in the same
    write — so the record still never ends at "I can't" SILENTLY, and the failure is on the thread
    where the next reader acts on it. Warning without dispatching is the failure this rule
    replaces, not a fallback: the fallback is the named refusal on the record, which the next hand
    (or the night) owes a dispatch.

### The completion review

16. A builder never settles the ask it was dispatched against. Completed work is SUBMITTED, not
    declared done: `crab eng review <id> <claim>` (kind `eng` only) moves an open record to state
    `review`, appends the claim as a dated entry, and bumps `last_touched` in the same write, so
    the record reads at a glance as "work claimed, not yet judged". Inside a builder session —
    the job runner exports `DESKCRAB_ENG_ROLE=builder` into the build, and every `crab eng` the
    builder runs inherits it — `settle` and `kill` are REFUSED, naming `crab eng review` as the
    one door for a completion claim (or an honest inability, which is also a claim for the review
    to judge); so are `accept` and `reject`, because the verdict belongs to the review, never to
    the hand under review. The origin (2026-08-26, record
    `the-chess-table-maintains-a-second-conversation`): the ask was the chess table as a thin
    client of the phone's VISIBLE conversation interface; the builder delivered shared audio
    plumbing — a clip-queue module both pages load — and the record was settled on it as
    "shared-primitive parity". Narrowed work that settles its own ask reads as the ask delivered,
    and nobody is ever brought back to the gap.
16a. The review itself is the completion wake of the job that submitted ([jobs.md](jobs.md) rules
    29a–29b): the waking session recovers the ORIGINAL ask and its acceptance criteria from the
    record's own opening entry, inspects the actual artefact or the visible behaviour directly —
    never the builder's report or claim alone — and decides whether the FULL ask and the full
    design were delivered. Two verdicts exist, both refused to a builder and both requiring state
    `review`: `crab eng accept <id> <what-was-verified>` settles the record with `settled_by`
    reading `review accepted: …`, and `crab eng reject <id> <missing…>` returns it to `open`.
16b. A rejection PRESERVES the missing requirements and redispatches them at once — in that
    order, because the dispatch runs a builder against the very record the rejection is still
    describing. The reject entry — state back to `open`, the reviewer's missing-requirements
    text verbatim — is WRITTEN AND ON DISK before the job door is opened, so the redispatched
    builder reads an open record already carrying what it owes; then the remaining work is
    redispatched through the job door (`crab job -f --record <id>`) with a brief that quotes
    those requirements and points at the record for the original ask. The redispatch is PLACED
    where the originating build ran: the door opens with `-C` on the `workdir` of the newest
    job sidecar carrying this record whose directory still exists — dispatch records the
    workdir on every sidecar exactly so a redispatch never retypes it ([jobs.md](jobs.md) rule
    7a's requeue discipline) — because the reviewing session sits in its own project
    directory, not in the repository that owns the artefact, and a follow-up dispatched bare
    starts a repository away from the work it owes. (That shape was live 2026-08-26: a
    rejected deskcrab build was redispatched into the reviewer's own project directory.) The
    `-C` lands on the new sidecar in turn, so the placement survives a chain of rejections
    even after the original sidecar is gone; the entry's outcome names the workdir whenever
    one was recovered. Only when no sidecar against the record offers a directory that still
    exists does the door's own default stand. The force is the
    reviewer's own deliberate hand ([jobs.md](jobs.md) rule 31): work already chosen once does
    not queue behind the night a second time. The job id and the door's outcome then land on
    that same reject entry by RE-READING the record, never by writing back the body loaded
    before the dispatch: a fast builder may already have touched — or submitted — in the window
    the dispatch held open, and every concurrent entry, the current state, and the current
    `last_touched` survive the annotation. (The lost-update shape this forbids was live:
    `cmd_reject` once loaded the record, dispatched while it was still in `review`, then wrote
    its pre-dispatch body back as `open`, erasing whatever a fast builder had written between.)
    When the annotation lands inside the standing entry it adds no entry and bumps nothing;
    only if that entry cannot be found does it fall back to a fresh dated entry, and THAT write
    stamps the attach epoch on the new sidecar exactly as the ending gate stamps it (rule 15b)
    — the pre-dispatch reject write needs no discounting, since the runner's floor is the
    dispatch moment itself. Either way the redispatched builder still owes the record its own
    entry — and its own submission. A dispatch the door refuses is named on the entry the same
    way, and the record still stands `open` from the write that preceded the attempt: the
    rejection is never lost to its own dispatch (rule 15c's discipline).
16c. `review` is a live state, not a closed one. It renders among the OPEN threads of the prompt
    block, marked as awaiting the review; it never ages out; and `settle` from it — the user's
    or the reviewer's own hand, outside a builder session — works exactly as rule 8 says. A
    record in a terminal state refuses a new submission; a record already in `review` accepts
    another, updating the claim while the state stands.
16d. The gate is the ROLE marker, not the tool: without `DESKCRAB_ENG_ROLE=builder` in the
    environment, `settle` and `kill` behave exactly as rule 8 wrote them, so the user's own
    hand — and the review's — is never refused anything. The marker is exported by
    `lib/job-runner` and by nothing else.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/engineering/records/<slug>.md` | frontmatter per rule 2, body per rule 3 |
| `~/.local/share/deskcrab/engineering.md`, `engineering/INDEX.md`, `engineering/*.md` | the pre-records archive: read-only history, still indexed in WHERE THINGS ARE |
| job sidecar field `record` | the engineering record a job was dispatched against ([jobs.md](jobs.md)) |
| job sidecar field `record_attached_epoch` | when rule 15b's attach write — or rule 16b's reject attach — touched the record, so the runner's rule-27 floor can discount it ([jobs.md](jobs.md)) |
| job sidecar field `workdir` | where rule 16b's redispatch is placed: the originating build's own repository, recorded at every dispatch ([jobs.md](jobs.md) rule 7a) |

## INTERACTIONS

**The tool may be called by:** the user and the assistant through `crab eng`, the prompt assembler
(`lib/eng prompt`), the job dispatch preflight (existence check), and the job runner
(`touched-since`).

**The tool must never:** speak, notify, book a wake, dispatch a job, or write outside its records
directory — with three exceptions: the write declaration of rule 10a, which goes to the
self-change watcher's suppression file through `crab touching`; the ending gate of rule 15; and
the review rejection of rule 16b — the latter two each dispatch through `crab job --record` (the
door's own policy intact for the gate, the reviewer's deliberate force for the reject) and stamp
`record_attached_epoch` on the sidecar they just created. All are the tool's own writes about its
own act, never a second writer of anything.

## TESTS

**Existing:** `tests/test_eng_records.sh` (round-trip, transitions bumping `last_touched`,
`touched-since`, search, the prompt rendering of open versus settled records — a settled record's
body prose stays out of the prompt — migration preserving dates and idempotence, and the bounded
index of rules 11–11a: review records lead, live and closed caps hold, omitted counts name their
retrieval doors, long lines remain bounded while their source record stays complete, a closure
inside the window renders and one well outside it does not, and `--compact` (the interactive turn)
is the closure count alone);
`tests/test_eng_selfchange.sh` (rule 10a: a real `crab eng touch` declares its own write and the
self-change watcher stays quiet about it, while an undeclared out-of-band edit to the same record
still raises a wake); `tests/test_job_record.sh` (the job hook, [jobs.md](jobs.md));
`tests/test_chore_gate.sh` (rules 15–15c: a touch ending at inability, and one ending at the
origin's chore shapes — a run-this command block and the ambiguous "Also unset:
TIDY_CLAIMS_ROOTS" — each dispatch exactly one builder against the record and land the job id on
the entry with `record_attached_epoch` on the sidecar; a second inability touch while that job
lives names the existing id and starts nothing; a note already carrying a job id, a conclusive
note, and inability mid-note all pass untouched; a refused dispatch is named on the entry and the
write survives; and the runner floor of rule 15b — an attach write newer than dispatch does not
stand in for the builder's own touch);
`tests/test_eng_review.sh` (rules 16–16d beside [jobs.md](jobs.md) rules 29a–29b: a submission
moves the record to `review`, bumps `last_touched`, and the prompt renders it live and marked,
never as settled; under the builder role, settle, kill, accept and reject are all refused with
the state standing, while the same hands work without the marker; accept settles only from
`review`, with the verdict on `settled_by`; reject returns the record to `open`, preserves the
missing requirements verbatim on the entry AND on the redispatched brief — sidecar `record` set,
`record_attached_epoch` stamped — and a dispatch the door refuses is named on the entry with the
reopen surviving; a reject issued from a FOREIGN current directory still places the follow-up in
the originating job's workdir, read off the newest sidecar against the record, the placement
survives a second rejection after the original sidecar is gone, and a recorded directory that no
longer exists falls back to the door's own default; the rejection is on disk as `open`, missing requirements included, by the
moment the dispatch runs, and a fast builder's touch and submission made during the dispatch
window both SURVIVE the job-id annotation — the entry, the `review` state, and the builder's
`last_touched` all stand (the rule 16b lost-update regression); and the 2026-08-26 regression
end to end: a builder that substituted shared audio plumbing for the asked-for visible reuse of
the phone conversation interface cannot settle the record — its settle is refused, its
submission leaves the record unsettled, the completion wake is the review brief at the review
effort pinned to the review model ([jobs.md](jobs.md) rule 29b), the reject carries the missing
interface requirement onto the next brief, and only an accepted submission settles the record).
