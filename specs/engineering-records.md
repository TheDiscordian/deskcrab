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

## CONTRACT

### The record

1. One file per thread: `~/.local/share/deskcrab/engineering/records/<slug>.md`. The directory is
   overridable as `DESKCRAB_ENG_DIR`, and every caller in the repo passes it explicitly from the
   instance's own data home, so a scratch instance's records stay in the scratch instance.
2. The file opens with YAML frontmatter carrying exactly these fields: `id` (the slug), `title`,
   `opened` (ISO local datetime), `last_touched` (ISO local datetime), `state`
   (`open` | `settled` | `dead`), `settled_at`, `settled_by` (who or what settled it), and
   `summary` (one line). `settled_at` and `settled_by` are empty while the record is open.
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
    rendered into the shelves layer. OPEN records render as live threads: title, id, `opened` and
    `last_touched` dates — always, whole. SETTLED and DEAD records render as the title plus ONE
    line — `settled <when>: <what settled it>` (or `dead <when>: <reason>`) — and never their body
    prose, so a resolved worry cannot be quoted back as present-tense fact. The settled tail is
    the shelf pattern, not the archive: the full rendering shows only recent closures (rule 11a's
    window, floor and cap) with the older tail as a pointer naming the drawer and
    `crab eng list --state all` as the way in; `--compact` (the interactive turn profile)
    shows the count line alone. The tail grows one line per settlement forever, and by 2026-08-15
    it alone was 20 KB of outcome essays on every speaking prompt — nothing is cut by this:
    every outcome stays on disk, whole, one command away. The rendering states plainly
    that the settled section is history, not live concerns.
    Detail in [prompt-assembly.md](prompt-assembly.md) rule 21a, which owns the layer.
11a. The settled section carries only RECENT closures. A closure renders when its `settled_at`
    falls inside a window (default 7 days, `DESKCRAB_ENG_PROMPT_WINDOW_DAYS`); whatever the window
    says, the most recent closures always render up to a floor (default 5,
    `DESKCRAB_ENG_PROMPT_MIN_CLOSED`) and never past a cap (default 25,
    `DESKCRAB_ENG_PROMPT_MAX_CLOSED`), the cap binding last. An older closure is not rendered in
    the block at all — it stays on disk, reachable exactly as before through
    `crab eng list --state all`, `crab eng show <id>` and `crab eng search` — and whenever
    anything is withheld the section's preamble says how many and names those doors, so the block
    never reads as though the history is gone. OPEN records are never aged out, however old their
    `last_touched`: an open thread is live by definition.
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

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/engineering/records/<slug>.md` | frontmatter per rule 2, body per rule 3 |
| `~/.local/share/deskcrab/engineering.md`, `engineering/INDEX.md`, `engineering/*.md` | the pre-records archive: read-only history, still indexed in WHERE THINGS ARE |
| job sidecar field `record` | the engineering record a job was dispatched against ([jobs.md](jobs.md)) |

## INTERACTIONS

**The tool may be called by:** the user and the assistant through `crab eng`, the prompt assembler
(`lib/eng prompt`), the job dispatch preflight (existence check), and the job runner
(`touched-since`).

**The tool must never:** speak, notify, book a wake, dispatch a job, or write outside its records
directory — with the one exception of the write declaration of rule 10a, which goes to the
self-change watcher's suppression file through `crab touching`.

## TESTS

**Existing:** `tests/test_eng_records.sh` (round-trip, transitions bumping `last_touched`,
`touched-since`, search, the prompt rendering of open versus settled records — a settled record's
body prose stays out of the prompt — migration preserving dates and idempotence, and the aging of
rule 11a: a closure inside the window renders and one well outside it does not, the floor holds
when every closure is old, the cap holds when many are recent, open records never age out, the
withheld pointer appears exactly when something was withheld, one case is pinned to its measured
byte size so regrowth is visible, and `--compact` (the interactive turn) is the count line alone);
`tests/test_eng_selfchange.sh` (rule 10a: a real `crab eng touch` declares its own write and the
self-change watcher stays quiet about it, while an undeclared out-of-band edit to the same record
still raises a wake); `tests/test_job_record.sh` (the job hook, [jobs.md](jobs.md)).
