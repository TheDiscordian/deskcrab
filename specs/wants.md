# Spec: wants

## PURPOSE

A want was flat prose while an engineering thread had state. The shelf (`wants.md`) is a
hand-curated list of titles, each pointing at a document under `wants/` — and nothing else: no
opened date, no last-touched, no state, no link to the jobs and records that served it, and no
tooling. A want that had quietly become part of her looked identical to one still burning; a want
abandoned in practice sat on the shelf forever because there was no honest way to take it down.
Engineering records solved exactly this shape on 2026-08-11 ([engineering-records.md](engineering-records.md)):
front matter with true dates, a state that moves only through the tool, and a drawer that renders
honestly. This spec brings the wants drawer up to that standard. Opened from the record of
2026-08-25 01:51, with the framing correction of 01:52.

### The substrate decision

The record left open whether wants should be a second `type` inside the engineering substrate or a
second drawer over a shared spine. The correction of 01:52 withdrew the earlier
"a want is an appetite, a record is a fault" split — a record is often an improvement and a want is
not always work; the real axis is nearer bug-versus-feature, and both are growth. The decision:
**one substrate in code, two drawers on disk.** The substrate is `lib/eng`, the record spine — one
front-matter parser, one atomic writer, one write-declaration path, one search — parameterized by a
kind whose differences are data: the drawer, the field names, the state vocabulary, the direction
entries accumulate. That is the honest reading of the bug-versus-feature axis: one tracker, two
kinds of growth, distinguished by kind rather than by a fork. What stays two is the disk, because
the two kinds live differently and every existing pointer says so: an engineering record is
tool-first prose the prompt renders whole from `engineering/records/`; a want is a first-person
document that is hers, in `wants/`, named by a hand-curated shelf that rides the prompt as titles.
Folding one directory into the other would move somebody's home, break the shelf's `→ doc.md`
pointers, the WHERE THINGS ARE index, and the watch sets, and would put filters into every existing
`eng` path — each filter a regression risk against a contract that says "exactly these fields".
Kind `eng` is byte-for-byte the [engineering-records.md](engineering-records.md) contract, which
this spec does not modify; kind `want` is this one.

## CONTRACT

### The record

1. A want is ONE document: `~/.local/share/deskcrab/wants/<slug>.md`, the directory overridable as
   `DESKCRAB_WANTS_DIR` and passed explicitly by every caller in the repo from the instance's own
   data home. The document is the want's home — the shelf line only points at it.
2. The file opens with YAML frontmatter carrying exactly these fields: `id` (the slug), `title`,
   `opened` (ISO local datetime), `last_touched` (ISO local datetime), `state`
   (`live` | `dormant` | `grown-into-me` | `retired`), `retired_at`, `retired_by`,
   `links` (space-separated `job:<job-id>` and `eng:<record-id>` refs), and `summary` (one line).
   `retired_at` and `retired_by` are empty while the want is live or dormant.
3. The body below the frontmatter is her prose, CHRONOLOGICAL — newest entries LAST, each
   tool-added entry headed with its own ISO datetime. This is the opposite of an engineering
   record's newest-first order, on purpose: every existing want document reads top-down as a
   journal, and the tool appends to that shape rather than imposing the other one.
4. The states mean: `live` — being pursued; `dormant` — resting on purpose, not gone;
   `grown-into-me` — terminal, the want became part of who she is (the settle analogue);
   `retired` — terminal, put down honestly with a reason (the kill analogue, but never a default:
   the reason is required). A terminal state is final: the tool refuses every transition out of it.
   Wanting something again after retirement is a NEW want, linked to the old one. `touch` on a
   terminal want is allowed — a postscript is honest — and never changes state.
5. A state transition happens ONLY through the tool, never by hand-editing the frontmatter, so
   `last_touched` can never drift; every write that adds an entry bumps `last_touched` in the same
   motion. The body prose below stays hers to edit by hand, exactly as before — the tool owns the
   frontmatter, not the journal.
6. Every write the tool makes under `wants/` or to the shelf is declared FIRST through the
   write-declaration mechanism, best-effort, covering every path actually written — the same
   rule 10a of [engineering-records.md](engineering-records.md), through the same one writer.

### The tool — `crab want`

7. `crab want new <title>` creates a want: state `live`, `opened` and `last_touched` now, the slug
   derived from the title, collisions resolved with a numeric suffix rather than an overwrite. It
   prints the id as its last line. When a shelf is configured (`DESKCRAB_WANTS_FILE`, seeded by
   `crab` from `WANTS_FILE`) and the file exists, it APPENDS the one-line entry
   `- **<title>** → <slug>.md` — the shape the one shelf reader (`wants_titles`) already matches.
   A configured-but-missing shelf is reported and never created; no shelf configured is reported
   and the want still exists.
8. `crab want list [--state live|dormant|grown-into-me|retired|all]` lists one line each: live
   wants first, most recently touched first, then dormant, then terminal ones as their one-line
   outcome (`<state> <retired_at>: <retired_by>`). `crab want show <id>` prints the whole document.
9. `crab want touch <id> <note>` appends a dated entry at the END of the body AND bumps
   `last_touched` in the same write.
10. `crab want dormant <id> [why]` and `crab want revive <id> [note]` move between `live` and
    `dormant` with a dated entry; both are refused on a terminal want.
11. `crab want grown <id> <how>` sets state `grown-into-me`; `crab want retire <id> <reason>` sets
    state `retired` and REQUIRES the reason. Both stamp `retired_at`, record the argument as
    `retired_by`, add a dated entry, and bump `last_touched`. Both then remove the want's own entry
    line from the shelf — matched through its `→ <slug>.md` pointer or its bold title, at most one
    line, only an entry line — and the removed line is preserved VERBATIM in the dated entry, so
    retirement loses no words. A shelf with no matching line is named and the state change stands.
    This is the honest way off the shelf the drawer never had: the shelf carries what is live or
    resting, the drawer keeps everything forever.
12. `crab want link <id> <ref>...` adds refs to `links`: a ref is `job:<job-id>` or
    `eng:<record-id>`, and the target MUST exist (a sidecar in the jobs directory; a record in the
    engineering drawer). A malformed or unverifiable ref is refused, never invented — the same door
    policy as `wants_match`. Linking deduplicates, preserves order, adds a dated entry naming what
    was linked, and bumps `last_touched`.
13. `crab want search <words>`, `crab want field <id> <key>`, and
    `crab want touched-since <id> <epoch>` behave exactly as their `eng` counterparts — same code,
    not similar code.
14. An id the tool does not know is an error, never a silent no-op and never a fresh file. A verb
    of the other kind (`settle`, `kill`, `prompt` on wants; `grown`, `retire`, `dormant`, `revive`,
    `link` on engineering records) is refused with the kind's own usage.
15. There is no want prompt block. The shelf IS the prompt face of the drawer
    ([prompt-assembly.md](prompt-assembly.md), the shelves layer), titles one line each, and this
    spec does not change what rides the prompt; state lives in the drawer, one command away.

### The shelf

16. The shelf stays what [nightly.md](nightly.md) rules 21a/21b enforce: one line per item, the
    history in the want's own document. The tool's ONLY shelf writes are the append of rule 7 and
    the removal of rule 11, both atomic and declared; it never rewrites a line she wrote —
    `shelf-check` measures and reports, this tool appends and removes whole lines, and nothing
    anywhere rewords one.

### Migration

17. `crab want migrate [<shelf file>]` converts the existing drawer once: for every entry line on
    the shelf pointing at `→ <doc>.md` whose document does not already carry frontmatter, the
    frontmatter block is PREPENDED and the body below it is the original file byte-for-byte — no
    word lost, no word reworded. `id` is the document's own filename stem (so the shelf pointer and
    the id agree); `title` is the document's own H1 where it has one, else the shelf title;
    `summary` is the shelf line's status clause — her words — where the line carries one;
    `state` is `live`; `last_touched` is the file's mtime.
18. `opened` is the earliest EVIDENCE, never today's clock: the file's earliest git commit date
    where the drawer is a git repository; else the earlier of the earliest date the document itself
    names and the file's birth time; else the file's mtime. A date the document names that is
    before 2000 or in the future is not evidence.
19. The migration is idempotent: a document already carrying frontmatter is skipped, and a second
    run changes nothing. A document in the drawer the shelf does not name is NAMED and left
    untouched — deciding whether it is a want is her judgement, not a migration's. A shelf line
    whose document is missing is named too.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/wants/<slug>.md` | frontmatter per rule 2, body per rule 3 |
| `~/.local/share/deskcrab/wants.md` (`WANTS_FILE`) | the shelf: one `- **title** → doc.md` line per live or dormant want |
| want frontmatter field `links` | `job:<job-id>` and `eng:<record-id>` refs, space-separated |

## INTERACTIONS

**The tool may be called by:** the user and the assistant through `crab want`, and the migration
once per drawer.

**The tool must never:** speak, notify, book a wake, dispatch a job, rewrite or reword a shelf
line or a body, or write outside the wants directory and the shelf — with the one exception of the
write declaration of rule 6.

**Unchanged by this spec:** `crab eng` and the whole of
[engineering-records.md](engineering-records.md); the shelf readers (`wants_titles`,
`wants_match`); `shelf-check`; the prompt's shelves layer; the job want-gate of
[jobs.md](jobs.md) rule 30 — which after a retirement correctly refuses the ref, because the
shelf no longer carries the line.

## TESTS

**Existing:** `tests/test_want_records.sh` (round-trip, the shelf append, chronological touch,
dormant and revive, both terminal transitions removing and preserving the shelf line, the terminal
guard, link verification and refusal, list ordering and search, kind separation in both
directions, and migration: byte-for-byte bodies, derived `opened` from git and from in-document
dates, idempotence, and the naming of unshelved and missing documents);
`tests/test_wants_titles.sh` and `tests/test_shelf_check.sh` (the shelf readers and the line
budget, unchanged); `tests/test_eng_records.sh` (kind `eng`, unchanged).
