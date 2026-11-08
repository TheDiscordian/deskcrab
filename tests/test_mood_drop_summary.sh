#!/bin/bash
# The dropped-mood count (specs/self-awareness.md rule 39a, face.md rule 42a):
# the stale-turn guard's refusals, counted instead of silent. The guard is
# correct and untouched — measured over five live days, a third of all mood
# sets were refused as stale and no surface anywhere said so, worst (62%)
# exactly at the desk. This suite drives the bounded journal reader
# (face_state.mood_drop_summary) over a fixture with every surface prefix,
# malformed and truncated lines, out-of-window rows and a missing file, then
# reads the state block whole and proves the line appears with refusals in
# the window and disappears without them.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
export DESKCRAB_FACE_SOCKET="$T/face.sock"
export DESKCRAB_FACE_STATE="$T/face-state.json"
export DESKCRAB_MOOD_JOURNAL="$T/mood-journal.jsonl"

FB() { python3 "$REPO_DIR/lib/face-broker" "$@"; }

echo "the reader — bounded, exact, and unraisable (rule 39a):"

# The fixture: fourteen sets inside a one-hour window at NOW=1788600000 —
# desktop (turn-…) 3 of 4 refused, phone 2 of 4, autonomous (wake-…) 1 of 5,
# one empty-token row (unknown surface, applied) — plus two sets outside the
# window, non-set journal events, and three broken lines.
python3 - "$T/fixture.jsonl" <<'PY'
import json
import sys

NOW = 1788600000.0
rows = [
    # (age, turn, mood, applied)
    (100, "turn-a-1", "focused", True),
    (200, "turn-b-2", "annoyed", False),
    (300, "turn-c-3", "tired", False),
    (400, "turn-d-4", "pleased", False),
    (500, "phone-a-1", "focused", True),
    (600, "phone-b-2", "pleased", True),
    (700, "phone-c-3", "annoyed", False),
    (800, "phone-d-4", "tired", False),
    (900, "wake-a-1", "focused", True),
    (1000, "wake-b-2", "focused", True),
    (1100, "wake-c-3", "pleased", True),
    (1200, "wake-d-4", "attentive", True),
    (1300, "wake-e-5", "annoyed", False),
    (1400, "", "attentive", True),
    # outside the one-hour window: a refusal and an application
    (7200, "turn-old-1", "annoyed", False),
    (9999, "phone-old-2", "pleased", True),
]
lines = []
for age, turn, mood, applied in rows:
    row = {"ts": NOW - age, "event": "set", "mood": mood, "reason": "r",
           "source": "s", "origin": "o", "source_ref": turn, "turn": turn,
           "applied": applied}
    if not applied:
        row["note"] = "stale turn — not applied"
    lines.append(json.dumps(row, separators=(",", ":")))
# Journal noise the reader must step over: other event kinds, a bad ts on a
# real-looking set, plain garbage that still contains the pre-filter token,
# a truncated write, and a non-JSON line.
lines.insert(3, json.dumps({"ts": NOW - 150, "event": "cleared",
                            "mood": "focused", "turn": "turn-a-1",
                            "applied": True}, separators=(",", ":")))
lines.insert(7, json.dumps({"ts": NOW - 650, "event": "expression",
                            "expression": "annoyed", "cause": "failed-action",
                            "applied": True}, separators=(",", ":")))
lines.insert(9, '{"ts":"bogus","event":"set","mood":"tired","turn":"turn-x-9","applied":false}')
lines.insert(11, 'garbage that still says "set" but is not a row')
lines.insert(13, '{"ts":1788599')
lines.insert(15, 'not json at all')
with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(lines) + "\n")
PY
check "totals: 14 attempted, 8 applied, 6 refused, rate 6/14" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2], window=3600,
                                 now=1788600000.0)
assert s["attempted"] == 14, s
assert s["applied"] == 8, s
assert s["refused"] == 6, s
assert abs(s["rate"] - 6 / 14) < 1e-9, s
assert s["window"] == 3600.0, s
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

check "per-surface rates: desktop 3/4, phone 2/4, autonomous 1/5, unknown 0/1" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2], window=3600,
                                 now=1788600000.0)
assert s["surfaces"] == {
    "desktop": {"attempted": 4, "refused": 3, "rate": 0.75},
    "phone": {"attempted": 4, "refused": 2, "rate": 0.5},
    "autonomous": {"attempted": 5, "refused": 1, "rate": 0.2},
    "unknown": {"attempted": 1, "refused": 0, "rate": 0.0},
}, s["surfaces"]
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

check "the worst surface is the highest-rate one, with its own counts" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2], window=3600,
                                 now=1788600000.0)
assert s["worst_surface"] == {"surface": "desktop", "attempted": 4,
                              "refused": 3, "rate": 0.75}, s["worst_surface"]
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

check "refused moods sort by rate, then by count on a rate tie" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2], window=3600,
                                 now=1788600000.0)
got = [(m["mood"], m["refused"], m["attempted"]) for m in s["refused_moods"]]
# annoyed and tired are both fully refused; annoyed refused more, so leads.
assert got == [("annoyed", 3, 3), ("tired", 2, 2), ("pleased", 1, 3)], got
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

check "widening the window admits the two older rows" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2], window=864000,
                                 now=1788600000.0)
assert s["attempted"] == 16 and s["refused"] == 7, s
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

check "a missing journal is the well-formed empty result, not an error" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2] + ".absent", window=3600,
                                 now=1788600000.0)
assert s == {"attempted": 0, "applied": 0, "refused": 0, "rate": 0.0,
             "window": 3600.0, "surfaces": {}, "worst_surface": None,
             "refused_moods": []}, s
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

printf '%s\n' 'not json' '{"ts":178' '"set"' > "$T/garbage.jsonl"
check "a journal of only broken lines is the empty result" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
s = face_state.mood_drop_summary(path=sys.argv[2], window=3600,
                                 now=1788600000.0)
assert s["attempted"] == 0 and s["refused"] == 0, s
PY' _ "$REPO_DIR" "$T/garbage.jsonl"

check "the byte bound reads only the tail and skips the seam's partial line" \
    bash -c 'python3 - "$1/lib" "$2" <<PY
import sys
sys.path.insert(0, sys.argv[1])
import face_state
with open(sys.argv[2], "rb") as fh:
    lines = fh.read().splitlines(keepends=True)
# Enough bytes for the last two rows plus a mid-line landing in the third.
bound = len(lines[-1]) + len(lines[-2]) + 10
s = face_state.mood_drop_summary(path=sys.argv[2], window=864000,
                                 max_bytes=bound, now=1788600000.0)
assert s["attempted"] == 2, s
PY' _ "$REPO_DIR" "$T/fixture.jsonl"

echo
echo "the state block — the line appears with refusals, and only then (rule 39a):"

FB mood pleased --reason "the fixture is thorough" --source "test bench" \
    >/dev/null
# The mood verb journals its own applied row; replace the journal wholesale
# with fixture rows stamped inside the live 24-hour window so the counts the
# block prints are exactly the fixture's.
python3 - "$T" <<'PY'
import json
import sys
import time

NOW = time.time()
rows = [
    (100, "turn-a-1", "focused", True),
    (200, "turn-b-2", "annoyed", False),
    (300, "turn-c-3", "tired", False),
    (400, "turn-d-4", "pleased", False),
    (500, "phone-a-1", "focused", True),
    (600, "phone-b-2", "pleased", True),
    (700, "phone-c-3", "annoyed", False),
    (800, "phone-d-4", "tired", False),
    (900, "wake-a-1", "focused", True),
    (1000, "wake-b-2", "focused", True),
    (1100, "wake-c-3", "pleased", True),
    (1200, "wake-d-4", "attentive", True),
    (1300, "wake-e-5", "annoyed", False),
    (1400, "", "attentive", True),
]
with open(sys.argv[1] + "/mood-journal.jsonl", "w") as fh:
    for age, turn, mood, applied in rows:
        row = {"ts": NOW - age, "event": "set", "mood": mood, "reason": "r",
               "source": "s", "origin": "o", "source_ref": turn,
               "turn": turn, "applied": applied}
        if not applied:
            row["note"] = "stale turn — not applied"
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
MOOD_SELF="$(sandbox_bash 'FACE_ENABLED=1; face_mood_report')"
contains "$MOOD_SELF" "How you feel: pleased" \
    && ok "the block still reads the standing mood beside the count" \
    || fail "the standing mood vanished from the block" "$MOOD_SELF"
contains "$MOOD_SELF" "Moods dropped unseen (last 24 h): 6 of 14" \
    && contains "$MOOD_SELF" "(43%)" \
    && ok "the line names refused of attempted and the overall rate" \
    || fail "the dropped-mood count is missing or wrong" "$MOOD_SELF"
contains "$MOOD_SELF" "worst surface: desktop, 3 of 4 (75%)" \
    && ok "the line names the worst surface with its own rate" \
    || fail "the worst surface is missing or wrong" "$MOOD_SELF"

# Every row applied: the guard refused nothing, and rule 39a says the line
# is omitted entirely — no empty table, no zero count.
python3 - "$T" <<'PY'
import json
import sys
import time

NOW = time.time()
with open(sys.argv[1] + "/mood-journal.jsonl", "w") as fh:
    for i, mood in enumerate(("focused", "pleased", "attentive")):
        fh.write(json.dumps(
            {"ts": NOW - 100 * (i + 1), "event": "set", "mood": mood,
             "reason": "r", "source": "s", "origin": "o",
             "source_ref": "turn-ok-%d" % i, "turn": "turn-ok-%d" % i,
             "applied": True}, separators=(",", ":")) + "\n")
PY
MOOD_SELF="$(sandbox_bash 'FACE_ENABLED=1; face_mood_report')"
contains "$MOOD_SELF" "How you feel: pleased" \
    && ! contains "$MOOD_SELF" "Moods dropped" \
    && ok "zero refusals in the window say nothing at all" \
    || fail "the line printed with nothing to report" "$MOOD_SELF"

rm -f "$T/mood-journal.jsonl"
MOOD_SELF="$(sandbox_bash 'FACE_ENABLED=1; face_mood_report')"
contains "$MOOD_SELF" "How you feel: pleased" \
    && ! contains "$MOOD_SELF" "Moods dropped" \
    && ok "a missing journal degrades to silence, never a broken block" \
    || fail "the missing journal broke the block" "$MOOD_SELF"

[ -f "$DESKCRAB_FACE_SOCKET.pid" ] \
    && kill "$(cat "$DESKCRAB_FACE_SOCKET.pid")" 2>/dev/null
true
