#!/usr/bin/env python3
"""Reseed the claudism negative corpus. By hand, never from a test, never
while the suite is running.

The corpus is PERSONAL data and lives outside this public repository, beside
its sources, at <data home>/deskcrab/claudism-negative-corpus/ (README.md
here carries the layout and the why).
This tool reads the live journal, the nightly review reports, the phrase
list and the want documents, and rewrites that directory:

  journal/YYYY-MM-DD.txt   spoken halves, one sentence per line, one file
                           per night that has BOTH a journal and a review
                           report; a review-flagged sentence is excluded
                           unless the current list no longer scores it a use
                           (an overturned flag is known-good again)
  docs/claudisms.md        the phrase list, snapshotted — the list the test
                           loads, and corpus text in its own right
  docs/wants/*.md          the want documents, snapshotted
  known-firing.tsv         the entries that fire on the reseeded corpus,
                           with counts (previous file kept as .prev)

canaries.txt is NEVER rewritten — canaries are named, once-litigated false
positives, appended by hand when a flag is overturned.

The scoring is lib/claudism-mirror's own — one parser, one mention test,
everywhere — and only USE-classified hits count. Read the printed table
before walking away: a NEW or GROWN entry is a pattern firing on known-good
speech, and this tool deliberately baselines it rather than hiding it, so
the person reseeding is the gate.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.expanduser(
    "~/.local/share")
STATE = os.environ.get("DESKCRAB_STATE") or os.path.join(DATA_HOME, "deskcrab")
CORPUS = os.environ.get("CLAUDISM_NEGATIVE_CORPUS") or os.path.join(
    STATE, "claudism-negative-corpus")


def load_mirror():
    p = os.path.join(REPO, "lib", "claudism-mirror")
    loader = importlib.machinery.SourceFileLoader("claudism_mirror", p)
    spec = importlib.util.spec_from_loader("claudism_mirror", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def entry_key(e):
    """The short name the trend tables use — claudism-corpus's derivation,
    kept identical."""
    key = re.split(r"\s+—\s+", e["note"] or "")[0]
    key = re.sub(r"[^a-z0-9]+", "-", key.lower()).strip("-")
    return key[:48] or re.sub(r"[^a-z0-9]+", "-", e["pat"].lower()).strip("-")[:48]


def main():
    mirror = load_mirror()
    list_path = os.path.join(STATE, "claudisms.md")
    patterns, bad = mirror.load_patterns(list_path)
    if not patterns:
        sys.stderr.write("seed.py: no usable entries in %s\n" % list_path)
        return 2
    print("patterns: %d (unparseable: %d)" % (len(patterns), bad))

    def use_keys(sent):
        out = []
        for e in patterns:
            cls = None
            for hit in e["rx"].finditer(sent):
                if mirror.classify_use(sent, hit.start(), hit.end(),
                                       e["note"]) == "use":
                    cls = "use"
                    break
                cls = "mention"
            if cls == "use":
                out.append(entry_key(e))
        return out

    def spoken_sentences(reply):
        spoken, _tail = mirror.split_spoken(reply)
        spoken = re.sub(r"```.*?```", " ", spoken, flags=re.S)
        return mirror.sentences(spoken)

    # -- the nights -----------------------------------------------------------
    jdir = os.path.join(STATE, "journal")
    rdir = os.path.join(STATE, "claudisms")
    nights = sorted(
        n[:-6] for n in os.listdir(jdir)
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}\.jsonl", n)
        and os.path.exists(os.path.join(rdir, n[:-6] + ".md")))
    if len(nights) < 3:
        sys.stderr.write("seed.py: only %d night(s) carry both a journal and "
                         "a review report — need 3\n" % len(nights))
        return 2

    outj = os.path.join(CORPUS, "journal")
    shutil.rmtree(outj, ignore_errors=True)
    os.makedirs(outj)
    total = 0
    for night in nights:
        with open(os.path.join(rdir, night + ".md"), encoding="utf-8") as f:
            report = f.read()
        kept, seen = [], set()
        excl = readmit = 0
        entries = []
        with open(os.path.join(jdir, night + ".jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if e.get("kind") == "job" or not e.get("reply"):
                    continue  # a job's entry is a builder's log, not speech
                entries.append(e)
        entries.sort(key=lambda e: e.get("epoch", 0))
        for e in entries:
            for s in spoken_sentences(e["reply"]):
                if s in seen:
                    continue
                seen.add(s)
                if s in report:
                    if use_keys(s):
                        excl += 1  # flagged then, firing now: not known-good
                        continue
                    readmit += 1   # flagged then, overturned since
                kept.append(s)
        with open(os.path.join(outj, night + ".txt"), "w",
                  encoding="utf-8") as f:
            f.write("\n".join(kept) + "\n")
        total += len(kept)
        print("night %s: %d kept, %d excluded (still-firing review quotes), "
              "%d re-admitted (overturned)" % (night, len(kept), excl, readmit))
    print("journal sentences: %d across %d nights" % (total, len(nights)))

    # -- the docs -------------------------------------------------------------
    docs = os.path.join(CORPUS, "docs")
    shutil.rmtree(docs, ignore_errors=True)
    os.makedirs(os.path.join(docs, "wants"))
    shutil.copy(list_path, os.path.join(docs, "claudisms.md"))
    for name in sorted(os.listdir(os.path.join(STATE, "wants"))):
        if name.endswith(".md"):
            shutil.copy(os.path.join(STATE, "wants", name),
                        os.path.join(docs, "wants", name))

    # -- score it and write the known-firing baselines ------------------------
    prev = {}
    tsv = os.path.join(CORPUS, "known-firing.tsv")
    if os.path.exists(tsv):
        with open(tsv, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    k, _, v = line.partition("\t")
                    if v.strip().isdigit():
                        prev[k] = int(v)
        shutil.copy(tsv, tsv + ".prev")

    stats = {k: [0, 0] for k in (entry_key(e) for e in patterns)}
    samples = {}
    n_sent = 0

    def score(sent):
        nonlocal n_sent
        n_sent += 1
        for e in patterns:
            cls = None
            for hit in e["rx"].finditer(sent):
                if mirror.classify_use(sent, hit.start(), hit.end(),
                                       e["note"]) == "use":
                    cls = 0
                    break
                cls = 1
            if cls is None:
                continue
            k = entry_key(e)
            stats[k][cls] += 1
            if cls == 0:
                samples.setdefault(k, [])
                if len(samples[k]) < 5:
                    samples[k].append(sent)

    for night in nights:
        with open(os.path.join(outj, night + ".txt"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    score(line)
    for root, _dirs, files in os.walk(docs):
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            with open(os.path.join(root, name), encoding="utf-8") as f:
                text = re.sub(r"```.*?```", " ", f.read(), flags=re.S)
            for sent in mirror.sentences(text):
                score(sent)

    rows = ["# entry-key\tuses-at-seeding — the ratchet baseline for",
            "# tests/test_claudism_negative_corpus.sh. Gated, not clean: the",
            "# test fails an entry that grows past its number, and fails a",
            "# listed entry that stops firing (take it off — the list only",
            "# shrinks). Seeded over %d sentences." % n_sent]
    warned = 0
    print("\n%-50s %5s %8s %9s" % ("entry", "uses", "mentions", "use-rate"))
    for k in sorted(stats):
        u, m = stats[k]
        print("%-50s %5d %8d %8.4f%%" % (k, u, m, 100.0 * u / n_sent))
        for s in samples.get(k, []):
            print("      | %s" % s)
        if u:
            rows.append("%s\t%d" % (k, u))
            if k not in prev:
                print("      ^ WARNING: NEW firing entry — was clean or "
                      "absent before this reseed. Read the samples above.")
                warned += 1
            elif u > prev[k]:
                print("      ^ WARNING: baseline GREW %d -> %d. Read the "
                      "samples above." % (prev[k], u))
                warned += 1
    with open(tsv, "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + "\n")

    canaries = os.path.join(CORPUS, "canaries.txt")
    if not os.path.exists(canaries):
        print("\nNOTE: %s does not exist. The canaries are hand-curated "
              "once-litigated false positives; the test fails without at "
              "least one. Write it by hand (lines starting # are comments)."
              % canaries)
    with open(os.path.join(CORPUS, "README.md"), "w", encoding="utf-8") as f:
        f.write("Seeded by tests/data/negative-corpus/seed.py from the "
                "deskcrab checkout — that directory's README.md is the "
                "contract. Personal data: never commit any of this into the "
                "repository.\n")

    print("\ncorpus sentences: %d; %d of %d entries firing; %d warning(s); "
          "known-firing.tsv rewritten at %s"
          % (n_sent, len(rows) - 5, len(stats), warned, tsv))
    return 0


if __name__ == "__main__":
    sys.exit(main())
