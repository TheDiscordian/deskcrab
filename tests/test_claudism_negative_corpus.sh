#!/bin/bash
# The claudism negative corpus — every pattern in the phrase list, scored
# against a seeded corpus of the assistant's own known-good speech, so a
# false positive costs a red line here instead of a good sentence at the
# gate. The corpus is PERSONAL data, read-only, outside the public
# repository, read through the harness's SANDBOX_LIVE_DATA under the touch
# gate — the same live-read convention test_claudism_parsers_agree.sh uses
# for the list itself (seeded by tests/data/negative-corpus/seed.py — that
# directory's README.md carries the layout and the why).
# Run: bash tests/test_claudism_negative_corpus.sh
#
# The measure is the per-pattern hit rate on known-good speech, not a bare
# pass/fail: the table below prints every entry's uses, mentions and rate on
# every run, and a firing entry quotes up to five matched sentences
# verbatim. Gating: an entry not named in known-firing.tsv must score ZERO
# uses; a named entry may not grow past its seeded baseline and may not
# silently reach zero (take it off — the list only shrinks, the same
# discipline as UNSANDBOXED in tests/run.sh). Canaries — once-litigated
# false positives, one sentence each — must score zero uses under the whole
# list, so putting a corrected regex back turns this file red on the exact
# sentence that was litigated. The scoring is lib/claudism-mirror's own:
# one parser, one mention test, everywhere; mentions are reported and gate
# nothing.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
CORPUS="${SANDBOX_LIVE_DATA:-}/claudism-negative-corpus"
OUT="$SANDBOX/negative-corpus"
mkdir -p "$OUT"

# The corpus is personal state: a clone without one runs the rest of the
# suite untouched, and says so rather than passing vacuously.
[ -n "${SANDBOX_LIVE_DATA:-}" ] && [ -d "$CORPUS" ] ||
    sandbox_skip "no negative corpus on this box — it is personal data, seeded by: python3 tests/data/negative-corpus/seed.py"

# The list the corpus was scored against is the list this test gates. A
# phrase list edited since the last reseed re-earns its green through a
# reseed read by a person — never through a silently drifting baseline.
[ -f "$SANDBOX_LIVE_DATA/claudisms.md" ] ||
    sandbox_skip "no live phrase list beside the corpus"
cmp -s "$CORPUS/docs/claudisms.md" "$SANDBOX_LIVE_DATA/claudisms.md" ||
    sandbox_skip "the phrase list changed since the corpus was seeded — reseed: python3 tests/data/negative-corpus/seed.py"

# --- score the corpus (read-only) with the repo's own scorer ---------------
python3 - "$REPO" "$CORPUS" "$OUT" <<'PY'
import importlib.machinery
import importlib.util
import os
import re
import sys

repo, corpus, out = sys.argv[1], sys.argv[2], sys.argv[3]

p = os.path.join(repo, "lib", "claudism-mirror")
loader = importlib.machinery.SourceFileLoader("claudism_mirror", p)
spec = importlib.util.spec_from_loader("claudism_mirror", loader)
mirror = importlib.util.module_from_spec(spec)
loader.exec_module(mirror)

patterns, bad = mirror.load_patterns(os.path.join(corpus, "docs", "claudisms.md"))


def entry_key(e):
    # claudism-corpus's derivation, kept identical
    key = re.split(r"\s+—\s+", e["note"] or "")[0]
    key = re.sub(r"[^a-z0-9]+", "-", key.lower()).strip("-")
    return key[:48] or re.sub(r"[^a-z0-9]+", "-", e["pat"].lower()).strip("-")[:48]


stats = {}
order = []
for e in patterns:
    k = entry_key(e)
    if k not in stats:
        stats[k] = [0, 0]
        order.append(k)
samples = {}
n_sent = 0


def hit_class(sent, e):
    cls = None
    for hit in e["rx"].finditer(sent):
        if mirror.classify_use(sent, hit.start(), hit.end(),
                               e["note"]) == "use":
            return 0
        cls = 1
    return cls


def score(sent):
    global n_sent
    n_sent += 1
    for e in patterns:
        cls = hit_class(sent, e)
        if cls is None:
            continue
        k = entry_key(e)
        stats[k][cls] += 1
        if cls == 0:
            samples.setdefault(k, [])
            if len(samples[k]) < 5:
                samples[k].append(sent)


nights = 0
j_sent = 0
jdir = os.path.join(corpus, "journal")
for name in sorted(os.listdir(jdir)) if os.path.isdir(jdir) else []:
    if not name.endswith(".txt"):
        continue
    nights += 1
    with open(os.path.join(jdir, name), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                j_sent += 1
                score(line)

docs = 0
for root, _dirs, files in os.walk(os.path.join(corpus, "docs")):
    for name in sorted(files):
        if not name.endswith(".md"):
            continue
        docs += 1
        with open(os.path.join(root, name), encoding="utf-8") as f:
            text = re.sub(r"```.*?```", " ", f.read(), flags=re.S)
        for sent in mirror.sentences(text):
            score(sent)

canaries = []
cpath = os.path.join(corpus, "canaries.txt")
if os.path.exists(cpath):
    with open(cpath, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                canaries.append(line)

with open(os.path.join(out, "verdict.tsv"), "w", encoding="utf-8") as v, \
     open(os.path.join(out, "samples.txt"), "w", encoding="utf-8") as s, \
     open(os.path.join(out, "table.txt"), "w", encoding="utf-8") as t, \
     open(os.path.join(out, "canary.tsv"), "w", encoding="utf-8") as c:
    v.write("meta\tpatterns\t%d\nmeta\tunparseable\t%d\nmeta\tnights\t%d\n"
            "meta\tjournal-sentences\t%d\nmeta\tsentences\t%d\nmeta\tdocs\t%d\n"
            "meta\tcanaries\t%d\n"
            % (len(patterns), bad, nights, j_sent, n_sent, docs, len(canaries)))
    t.write("the corpus: %d sentences (%d journal across %d nights, %d docs)"
            " against %d patterns\n" % (n_sent, j_sent, nights, docs,
                                        len(patterns)))
    t.write("%-50s %5s %8s  %s\n" % ("entry", "uses", "mentions",
                                     "use-rate (uses / corpus sentences)"))
    for k in order:
        u, m = stats[k]
        v.write("entry\t%s\t%d\t%d\t%.4f%%\n" % (k, u, m,
                                                 100.0 * u / max(n_sent, 1)))
        t.write("%-50s %5d %8d  %.4f%%\n" % (k, u, m,
                                             100.0 * u / max(n_sent, 1)))
        for sent in samples.get(k, []):
            s.write("%s\t%s\n" % (k, sent))
            t.write("      | %s\n" % sent)
    for i, sent in enumerate(canaries, 1):
        keys = ",".join(k for k in order for e in patterns
                        if entry_key(e) == k and hit_class(sent, e) == 0)
        c.write("%d\t%s\t%s\n" % (i, keys or "-", sent))
PY
check "the scorer ran over the corpus" test -s "$OUT/verdict.tsv"
[ -s "$OUT/verdict.tsv" ] || die "nothing to gate on"

echo
sed 's/^/  # /' "$OUT/table.txt"
echo

meta() { awk -F'\t' -v k="$2" '$1=="meta" && $2==k {print $3}' "$1"; }

# --- the corpus is big enough to mean something ----------------------------
NIGHTS="$(meta "$OUT/verdict.tsv" nights)"
TOTAL="$(meta "$OUT/verdict.tsv" sentences)"
check "every pattern in the snapshot parsed (0 unparseable)" \
    [ "$(meta "$OUT/verdict.tsv" unparseable)" = 0 ]
check "patterns loaded from the corpus snapshot" \
    [ "$(meta "$OUT/verdict.tsv" patterns)" -ge 1 ]
check "at least three distinct nights of journal speech ($NIGHTS)" \
    [ "$NIGHTS" -ge 3 ]
check "at least 1000 journal sentences ($(meta "$OUT/verdict.tsv" journal-sentences))" \
    [ "$(meta "$OUT/verdict.tsv" journal-sentences)" -ge 1000 ]
check "the docs ride along — the list itself and the want documents" \
    [ "$(meta "$OUT/verdict.tsv" docs)" -ge 2 ]
check "at least one canary sentence" \
    [ "$(meta "$OUT/verdict.tsv" canaries)" -ge 1 ]

# --- per pattern: zero on known-good speech, or a named, shrinking ratchet -
KNOWN="$CORPUS/known-firing.tsv"
baseline() { # <key> -> baseline count, or empty
    [ -f "$KNOWN" ] || return 0
    awk -F'\t' -v k="$1" '!/^#/ && $1==k {print $2}' "$KNOWN"
}

while IFS=$'\t' read -r tag key uses mentions rate; do
    [ "$tag" = entry ] || continue
    b="$(baseline "$key")"
    if [ -z "$b" ]; then
        if [ "$uses" = 0 ]; then
            ok "$key: 0 uses on $TOTAL known-good sentences ($mentions mentions)"
        else
            fail "$key: fires on known-good speech" "$uses uses, rate $rate"
            grep -F "$key	" "$OUT/samples.txt" | cut -f2- | sed 's/^/        matched: /'
        fi
    else
        if [ "$uses" = 0 ]; then
            fail "$key: gated entry no longer fires — take it off known-firing.tsv (the list only shrinks)"
        elif [ "$uses" -gt "$b" ]; then
            fail "$key: grew past its known-firing baseline" "$uses uses, baseline $b, rate $rate"
            grep -F "$key	" "$OUT/samples.txt" | cut -f2- | sed 's/^/        matched: /'
        else
            ok "$key: GATED, not clean — $uses uses within baseline $b, rate $rate"
        fi
    fi
done < "$OUT/verdict.tsv"

# A baseline row for an entry the list no longer has is a stale excuse.
if [ -f "$KNOWN" ]; then
    while IFS=$'\t' read -r key b; do
        case "$key" in ''|'#'*) continue ;; esac
        grep -q "^entry	$key	" "$OUT/verdict.tsv" ||
            fail "known-firing.tsv names an entry the list no longer has: $key"
    done < "$KNOWN"
fi

# --- the canaries: the exact sentences that were litigated -----------------
while IFS=$'\t' read -r idx keys sent; do
    [ -n "$sent" ] || continue
    if [ "$keys" = "-" ]; then
        ok "canary $idx scores zero uses"
    else
        fail "canary $idx fires ($keys)" "$sent"
    fi
done < "$OUT/canary.tsv"
