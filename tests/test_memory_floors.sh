#!/bin/bash
# memory-recall.md rules 13e and 13f: the calibrated retrieval floors, the
# relative margin, the abstain instrument, and the knob resolution order.
#
# Stubbed embeddings throughout — no network, no embedder, no model calls of
# any kind: every vector is constructed by hand in a driver that replaces
# memory.embed before any store is opened, so each case controls a row's raw
# similarity, its null-projected similarity, and the query's cosine to the
# contentless direction independently. What is pinned:
#
#   - each of the three absolute floors (note 0.50, directive 0.49,
#     episodic 0.485) demonstrably cuts a constructed record that the old
#     inert floors (0.35 / 0.28 / 0.30) let through;
#   - the relative margin cuts a trailer more than MEMORY_SIM_MARGIN below
#     the query's best match even though it clears every absolute floor;
#   - a high-similarity real-shaped query keeps its full top-K;
#   - a query whose whole pool sits under the bar returns the abstained
#     result — "empty" when the floors cut everything, "null-query" when the
#     query IS the contentless direction — with pinned rows still riding
#     through, the recall block rendering the one neutral marker, and no ids
#     sidecar;
#   - the low-signal gate SHIPS OFF (rule 13f: the instrument measures
#     brevity, not relevance): under default settings a null-direction pool
#     no longer abstains, queries shaped like the measured short-turn band
#     ('hey' 0.169, "what's up" 0.176, 'ok' 0.168 — all under the retired
#     0.18 bar) keep their rows, and a bare full stop still abstains as
#     null-query; an explicit positive MEMORY_ABSTAIN_FLOOR re-engages the
#     gate exactly as before;
#   - every knob resolves environment first, conf second, shipped default
#     last, and a missing conf degrades silently to the defaults.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
WORK="$SANDBOX/floors"
mkdir -p "$WORK"
PY="${MEMORY_PYTHON:-python3}"
"$PY" -c "import sqlite_vec" 2>/dev/null \
    || sandbox_skip "no sqlite-vec interpreter (MEMORY_PYTHON) on this box"

cat > "$WORK/driver.py" <<'EOF'
#!/usr/bin/env python3
"""One constructed-store case per invocation, stubbed embeddings only."""
import importlib.util, io, json, math, os, sys, tempfile
from argparse import Namespace
from contextlib import redirect_stdout

REPO, CASE, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("memory", REPO + "/lib/memory.py")
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)

D = memory.EMBED_DIM
def unit(*pairs):
    v = [0.0] * D
    for i, val in pairs:
        v[i] = val
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v]

NULL = unit((0, 1.0))
def q_with_null(c):
    """A query vector whose cosine to the contentless direction is c."""
    return unit((0, c), (1, math.sqrt(1 - c * c)))
def doc(target, c=0.3, axis=2):
    """A doc whose raw cosine to q_with_null(c) is `target`; distinct `axis`
    keeps constructed docs out of each other's near-dup radius."""
    b = target / math.sqrt(1 - c * c)
    return unit((1, b), (axis, math.sqrt(max(0.0, 1 - b * b))))

VECS = {"": NULL}
memory.embed = lambda texts, query=False, timeout=30: [VECS[t] for t in texts]

sdir = tempfile.mkdtemp(prefix="floors-", dir=WORK)
os.environ.setdefault("DESKCRAB_CONDUCT_DIR", os.path.join(sdir, "conduct"))
store = memory.Store(sdir)
Q = "what does the store hold about this"
VECS[Q] = q_with_null(0.3)

def result(rows, abstained, extra=None):
    out = {"kept": sorted(r[1] for r in rows), "abstained": abstained}
    if extra:
        out.update(extra)
    print("RESULT " + json.dumps(out))

if CASE == "floors":
    store.insert("kept note", kind="note", vec=doc(0.60))
    store.insert("cut note", kind="note", vec=doc(0.42, axis=3))
    store.insert("kept directive", kind="directive", vec=doc(0.60, axis=4))
    store.insert("cut directive", kind="directive", vec=doc(0.40, axis=5))
    store.insert("kept episodic", kind="episodic", vec=doc(0.60, axis=6))
    store.insert("cut episodic", kind="episodic", vec=doc(0.40, axis=7))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
elif CASE == "margin":
    store.insert("best note", kind="note", vec=doc(0.90))
    store.insert("trailing note", kind="note", vec=doc(0.55, axis=3))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
elif CASE == "fullset":
    for i in range(8):
        store.insert("note %d" % i, kind="note",
                     vec=doc(0.58 + i * 0.01, axis=2 + i))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
elif CASE == "lowsignal":
    # Raw similarity clears every floor; null-projected similarity is zero.
    # With the gate shipped off (ABSTAIN_FLOOR 0) this abstains nothing and
    # keeps the note; an explicit positive MEMORY_ABSTAIN_FLOOR in the
    # environment re-engages the gate and the shell asserts both faces.
    VECS[Q] = q_with_null(0.8)
    store.insert("background note", kind="note", vec=unit((0, 1.0)))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
elif CASE == "shortturns":
    # The measured 2026-09-03 short-turn band: best null-projected
    # similarity 'hey' 0.169, "what's up" 0.176, 'ok' 0.168 — every one a
    # real turn, every one under the retired 0.18 default. Each query is
    # built to that projected best over a note whose raw similarity (0.55)
    # clears every floor: with the low-signal gate shipped off, none of
    # them may abstain and each keeps its note.
    out = {}
    c = 0.6
    s = math.sqrt(1 - c * c)
    for i, (text, p) in enumerate(
            [("hey", 0.169), ("what's up", 0.176), ("ok", 0.168)]):
        VECS[text] = unit((0, c), (1, s))
        d0 = (0.55 - s * p) / c
        rest = math.sqrt(max(0.0, 1 - d0 * d0 - p * p))
        st = memory.Store(tempfile.mkdtemp(prefix="short-", dir=WORK))
        st.insert("kept note", kind="note",
                  vec=unit((0, d0), (1, p), (2 + i, rest)))
        rows, _, _, abst = st.search(text)
        out[text + " abstained"] = abst
        out[text + " kept"] = sorted(r[1] for r in rows)
    print("RESULT " + json.dumps(out))
elif CASE == "dot":
    # A bare full stop measures 0.910 on the contentless direction where no
    # real query in either corpus came near (0.815 / 0.694): the null-query
    # gate must hold with the low-signal gate off, and a note whose raw
    # similarity would sail through the floors must not ride an abstention.
    VECS["."] = q_with_null(0.91)
    store.insert("tempting note", kind="note", vec=unit((0, 0.7), (1, 0.55)))
    rows, _, _, abst = store.search(".")
    result(rows, abst)
elif CASE == "nullq":
    VECS[Q] = q_with_null(0.9)
    store.insert("some note", kind="note", vec=doc(0.55, c=0.9))
    store.insert("pinned rule", kind="directive", pinned=True,
                 vec=unit((3, 1.0)))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
elif CASE == "empty":
    store.insert("weak note", kind="note", vec=doc(0.42))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
elif CASE == "block":
    store.insert("weak note", kind="note", vec=doc(0.42))
    ids_out = os.path.join(WORK, "ids-out.json")
    args = Namespace(query=Q, reason="", wants="", convo="", wake=False,
                     log="", notes=8, directives=10, episodes=5, max_chars=0,
                     scope=(), ids_out=ids_out)
    buf = io.StringIO()
    with redirect_stdout(buf):
        memory.cmd_recall_block(store, args)
    bare_block, bare_sidecar = buf.getvalue(), os.path.exists(ids_out)
    store.insert("pinned rule", kind="directive", pinned=True,
                 vec=unit((3, 1.0)))
    buf = io.StringIO()
    with redirect_stdout(buf):
        memory.cmd_recall_block(store, args)
    print("RESULT " + json.dumps({
        "block": bare_block, "sidecar": bare_sidecar,
        "pinned_block": buf.getvalue(),
        "pinned_sidecar": os.path.exists(ids_out)}))
elif CASE == "knob":
    store.insert("kept note", kind="note", vec=doc(0.60))
    rows, _, _, abst = store.search(Q)
    result(rows, abst)
else:
    sys.exit("unknown case " + CASE)
EOF

run_case() {  # run_case <case> [env VAR=VAL ...] -> RESULT json on stdout
    local case="$1"; shift
    env DESKCRAB_CONF="${DRIVER_CONF:-/nonexistent-floors-conf}" "$@" \
        "$PY" "$WORK/driver.py" "$REPO" "$case" "$WORK" 2>"$WORK/err" \
        | sed -n 's/^RESULT //p'
}
field() { printf '%s' "$1" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d[sys.argv[1]])" "$2" 2>/dev/null; }

# --- the three absolute floors, and only they, cut -------------------------
R="$(run_case floors)"
check_eq "the note floor cuts a 0.42 note the old 0.35 floor kept, keeping the 0.60 one" \
    "$(field "$R" kept)" "['kept directive', 'kept episodic', 'kept note']"
check_eq "a query with survivors is not abstained" "$(field "$R" abstained)" ""

# --- the relative margin ---------------------------------------------------
R="$(run_case margin)"
check_eq "a trailer 0.35 under the best is cut by the margin though it clears every absolute floor" \
    "$(field "$R" kept)" "['best note']"

# --- a real-shaped query keeps its full set --------------------------------
R="$(run_case fullset)"
check_eq "eight notes inside floor and margin all arrive" \
    "$(field "$R" kept)" \
    "['note 0', 'note 1', 'note 2', 'note 3', 'note 4', 'note 5', 'note 6', 'note 7']"

# --- abstention ------------------------------------------------------------
# The low-signal gate ships OFF (rule 13f): the instrument measures brevity,
# not relevance, so under default settings a null-direction pool keeps its
# rows and only a deliberate positive floor re-engages the gate.
R="$(run_case lowsignal)"
check_eq "with the gate shipped off, a raw-high null-direction pool does not abstain" \
    "$(field "$R" abstained)" ""
check_eq "the shipped defaults keep the note the 0.18 gate used to cut" \
    "$(field "$R" kept)" "['background note']"

R="$(run_case lowsignal MEMORY_ABSTAIN_FLOOR=0.18)"
check_eq "an explicit positive floor re-engages the low-signal gate as before" \
    "$(field "$R" abstained)" "low-signal"
check_eq "an engaged low-signal gate returns no similarity rows" \
    "$(field "$R" kept)" "[]"

R="$(run_case shortturns)"
for T in "hey" "what's up" "ok"; do
    check_eq "the short real turn '$T' does not abstain under default settings" \
        "$(field "$R" "$T abstained")" ""
    check_eq "the short real turn '$T' keeps its note" \
        "$(field "$R" "$T kept")" "['kept note']"
done

R="$(run_case dot)"
check_eq "a bare full stop still abstains as null-query under default settings" \
    "$(field "$R" abstained)" "null-query"
check_eq "no similarity row rides the full stop's abstention" \
    "$(field "$R" kept)" "[]"

R="$(run_case nullq)"
check_eq "a query that is the contentless direction abstains as null-query" \
    "$(field "$R" abstained)" "null-query"
check_eq "pinned rows ride through an abstention" \
    "$(field "$R" kept)" "['pinned rule']"

R="$(run_case empty)"
check_eq "floors cutting the whole pool return the abstained empty result" \
    "$(field "$R" abstained)" "empty"

R="$(run_case block)"
BLOCK="$(field "$R" block)"
check "the recall block renders the one neutral abstention marker" \
    contains "$BLOCK" "(nothing relevant retrieved)"
check "the weak note stays out of the abstained block" \
    bash -c '! grep -qF "weak note" <<<"$1"' _ "$BLOCK"
check_eq "an abstained block with nothing to ride writes no ids sidecar" \
    "$(field "$R" sidecar)" "False"
PBLOCK="$(field "$R" pinned_block)"
check "the pinned rule still renders beneath the marker" \
    contains "$PBLOCK" "pinned rule"
check "the marker survives beside a riding pinned row" \
    contains "$PBLOCK" "(nothing relevant retrieved)"
check_eq "a riding pinned row still reaches the ids sidecar" \
    "$(field "$R" pinned_sidecar)" "True"

# --- knob resolution: environment first, conf second, default last ---------
R="$(run_case knob)"
check_eq "no environment, no conf: the shipped default keeps the 0.60 note" \
    "$(field "$R" kept)" "['kept note']"

CONF="$WORK/floors.conf"
printf 'MEMORY_SIM_FLOOR="0.95"\n' > "$CONF"
R="$(DRIVER_CONF="$CONF" run_case knob)"
check_eq "a conf floor of 0.95 cuts what the default kept" \
    "$(field "$R" abstained)" "empty"

R="$(DRIVER_CONF="$CONF" run_case knob MEMORY_SIM_FLOOR=0.30)"
check_eq "an environment floor beats the conf floor" \
    "$(field "$R" kept)" "['kept note']"

R="$(run_case knob MEMORY_ABSTAIN_FLOOR=0.99)"
check_eq "the abstain bar is a knob too: raised over the pool it abstains" \
    "$(field "$R" abstained)" "low-signal"

R="$(DRIVER_CONF=/nonexistent-floors-conf run_case knob)"
check_eq "a missing conf degrades silently to the shipped defaults" \
    "$(field "$R" kept)" "['kept note']"
