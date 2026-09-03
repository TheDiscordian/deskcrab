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
#     result — "empty" when the floors cut everything, "low-signal" when no
#     null-projected similarity survives, "null-query" when the query IS the
#     contentless direction — with pinned rows still riding through, the
#     recall block rendering the one neutral marker, and no ids sidecar;
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
    VECS[Q] = q_with_null(0.8)
    store.insert("background note", kind="note", vec=unit((0, 1.0)))
    rows, _, _, abst = store.search(Q)
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
R="$(run_case lowsignal)"
check_eq "raw-high background rows abstain as low-signal" \
    "$(field "$R" abstained)" "low-signal"
check_eq "low-signal returns no similarity rows" "$(field "$R" kept)" "[]"

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
