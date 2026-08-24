# The claudism negative corpus — known-good speech every pattern must not fire on

A claudism pattern is written from one incident and never tested against
speech that is FINE, so a false positive costs a good sentence — the old
bare-cessation regex holding a perfectly good line about a chess game going
well (2026-08-17 02:07) is the founding case, on the engineering record that
asked for this. The corpus is the missing denominator: the user's assistant's
own real, correct sentences, scored against every pattern in the phrase list
on every suite run by `tests/test_claudism_negative_corpus.sh`. The measure
is the per-pattern hit rate on known-good speech, not the count and not a
bare pass/fail — the test prints the full table every run and quotes what
fired.

**The corpus data is personal and is NOT in this repository.** This repo is
public, and its standing rule — no personal data in any committed file —
outranks the convenience of fixture-style data. The phrase list itself is
already "personal state, never in this repository" (`lib/claudism-scan`); the
corpus is a night-by-night transcript of the assistant's own speech and the
user's want documents, which is more personal still. What lives here is the
tooling and the contract; the data lives beside its sources, in the live
state directory, at `<data home>/deskcrab/claudism-negative-corpus/`. The
test reads it read-only through the harness's `SANDBOX_LIVE_DATA`, the
same convention `test_claudism_parsers_agree.sh` and the chess suite
already use for live state, under the touch gate (test-harness rule 9)
that fails any test that writes what it read; it skips out loud where the
corpus is absent, so a public clone runs the rest of the suite untouched.

The layout `seed.py` writes there:

- `journal/YYYY-MM-DD.txt` — one sentence per line: the SPOKEN halves of the
  assistant's journal replies (jobs excluded, display halves cut, code
  fences cut, sentence-split by `lib/claudism-mirror`'s own splitter), one
  file per night that has BOTH a journal and a nightly review report. A
  sentence that night's review flagged is excluded — unless the current
  pattern list no longer scores it a use, in which case the flag was
  overturned by a later correction and the sentence is re-admitted as
  known-good (the founding sentence is in the corpus exactly this way).
- `docs/claudisms.md` — the phrase list, snapshotted at seed time, playing
  two roles: it is the list the test LOADS (so a run is deterministic
  between reseeds), and it is corpus text in its own right, because the
  record shows patterns firing on their own documentation. The test compares
  it byte-for-byte with the live list and SKIPS, naming the reseed command,
  when they have diverged — an edited list re-earns its green through a
  reseed, read by a person, never silently.
- `docs/wants/*.md` — every want document, known-good by decree, snapshotted
  the same way.
- `canaries.txt` — hand-curated single sentences that must score ZERO uses
  under the whole list, each a named, once-litigated false positive; the
  founding bare-cessation sentence is the first. `seed.py` never rewrites
  this file. Lines starting `#` are comments.
- `known-firing.tsv` — the entries that DO fire on the corpus as of seeding,
  with their use-counts. These are GATED, not clean: the test asserts zero
  uses for every entry not listed, and for a listed entry that the count
  never grows past its baseline and never silently reaches zero — an entry
  that stops firing must come off the list, so the list only shrinks (the
  same discipline as UNSANDBOXED in `tests/run.sh`). At first seeding
  (2026-08-24) nineteen of twenty-five entries were firing, overwhelmingly
  the wide review-only nets (`live: no`) and plain uses of listed words
  inside the user's own documentation; per the record's rule the patterns
  are left alone and the hits are reported, never quietly excused.

The scoring is the nightly review's exactly: `load_patterns`, `sentences`
and the mention-vs-use classifier from `lib/claudism-mirror` — one parser,
one mention test, everywhere. Only USE-classified hits gate; mentions are
reported in the table and gate nothing.

Reseeding, by hand, never from a test, never while the suite is running (the
touch gate photographs live state and would accuse whichever test was mid
run): `python3 tests/data/negative-corpus/seed.py`. It rewrites the journal
files, the doc snapshots and `known-firing.tsv` (keeping the old baselines
in `known-firing.tsv.prev`), and prints the per-pattern table — with a loud
warning for every entry whose count GREW and every newly-firing entry, which
is the moment a person decides whether the pattern or the baseline is wrong.
A baseline that grew is a pattern getting worse on known-good speech, and
deserves the record's attention, not a bigger number.
