#!/bin/bash
# The expiry a limit refusal records — specs/model-backends.md rule 13. When
# the provider's refusal quotes its own reset time ("try again at Sep 6th,
# 2026 10:28 PM"), THAT epoch is blocked-until and the line says `reported`;
# a refusal quoting nothing usable — no time, a past time, a time beyond the
# week cap, a clause cut off mid-time — falls back to the flat
# CODEX_LIMIT_COOLDOWN window and the line says `estimated`. Both recorders
# are pinned: codex_limit_record in lib/common.sh and its mirror in
# lib/memory.py, and the four-field line must still read through
# codex_limit_until and codex_cooling_until — honoured while it stands,
# ignored once expired. Run: bash tests/test_limit_expiry.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
CODEX_STATE="$SANDBOX/codex-state"

cat > "$DESKCRAB_CONF" <<EOF
PROJECT_DIR="$SANDBOX/home"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
EOF

# codex_available needs an executable to find before it consults the cooldown.
sandbox_stub codex <<'STUB'
#!/bin/bash
exit 0
STUB

sb() { DESKCRAB_CODEX_STATE="$CODEX_STATE" sandbox_bash "$@"; }
field() { awk -F'\t' -v n="$1" '$1 == "blocked-until" {print $n; exit}' "$CODEX_STATE" 2>/dev/null; }

# The sentence measured in the wild on 2026-09-02, verbatim.
WILD="You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 6th, 2026 10:28 PM."
WILD_EPOCH="$(date -d '2026-09-06 22:28' +%s)"

# A clause the recorder must honour whatever day the suite runs: two days out,
# minute-truncated, in the provider's own spelling (ordinal day, 12-hour clock).
TARGET="$(date -d '+2 days' '+%Y-%m-%d %H:%M')"
TARGET_EPOCH="$(date -d "$TARGET" +%s)"
DAY="$(date -d "$TARGET" '+%-d')"
case "$DAY" in 1|21|31) ORD=st ;; 2|22) ORD=nd ;; 3|23) ORD=rd ;; *) ORD=th ;; esac
CLAUSE="$(date -d "$TARGET" "+%b ${DAY}${ORD}, %Y %-I:%M %p")"
MSG_REPORTED="You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at ${CLAUSE}."
MSG_PAST="You have hit your usage limit — try again at Sep 6th, 2020 10:28 PM."
MSG_FAR="You have hit your usage limit — try again at $(date -d '+30 days' '+%b %-d, %Y %-I:%M %p')."
MSG_TRUNC="You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 6th, 2026 10:"
MSG_MIXED="${MSG_TRUNC} — or try again at ${CLAUSE}."
export WILD MSG_REPORTED MSG_PAST MSG_FAR MSG_TRUNC MSG_MIXED

flat_window() {  # <epoch> <before> <after> — now+1800, measured around the call
    [ -n "$1" ] && [ "$1" -ge $(( $2 + 1800 )) ] && [ "$1" -le $(( $3 + 1800 )) ]
}

echo "the shell parse — the provider's clause, read exactly (rule 13):"
check_eq "the wild sentence parses to Sep 6th 2026, 22:28 local" \
    "$(sb 'codex_limit_reset_parse "$WILD"')" "$WILD_EPOCH"

echo
echo "the shell recorder — a reported expiry is the provider's own answer:"
rm -f "$CODEX_STATE"
sb 'codex_limit_record "$MSG_REPORTED"'
check_eq "blocked-until is the quoted epoch, not now+1800" "$(field 2)" "$TARGET_EPOCH"
check_eq "…and the trailing marker says reported" "$(field 4)" "reported"
check "the refusal text still rides the line" \
    contains "$(field 3)" "hit your usage limit"
check_eq "codex_limit_until honours the reported expiry" \
    "$(sb 'codex_limit_until')" "$TARGET_EPOCH"
sb 'codex_available' \
    && fail "a reported cooldown must bench codex" "$(cat "$CODEX_STATE")" \
    || ok "while the reported cooldown stands codex is unavailable"

echo
echo "how that expiry is SPOKEN — a bare clock time is only honest for today:"
check_eq "a reported expiry days out carries its date" \
    "$(sb "codex_cooling_clock $WILD_EPOCH")" \
    "$(date -d "@$WILD_EPOCH" '+%b %-d, %H:%M')"
check_eq "…and the status line says it that way too" \
    "$(sb 'codex_unavailable_why')" \
    "cooling until $(date -d "@$TARGET_EPOCH" '+%b %-d, %H:%M')"
check_eq "a cooldown later today stays a bare clock time" \
    "$(sb 'codex_cooling_clock "$(( $(date +%s) + 300 ))"')" \
    "$(date -d "@$(( $(date +%s) + 300 ))" '+%H:%M')"

echo
echo "the shell recorder — everything unclear falls back to the flat window:"
rm -f "$CODEX_STATE"; BEFORE="$(date +%s)"
sb 'codex_limit_record "You have hit your usage limit."'
AFTER="$(date +%s)"
flat_window "$(field 2)" "$BEFORE" "$AFTER" \
    && ok "no quoted time still gets now + CODEX_LIMIT_COOLDOWN" \
    || fail "no quoted time must fall back to the flat window" "$(field 2)"
check_eq "…marked estimated" "$(field 4)" "estimated"

rm -f "$CODEX_STATE"; BEFORE="$(date +%s)"
sb 'codex_limit_record "$MSG_PAST"'
AFTER="$(date +%s)"
flat_window "$(field 2)" "$BEFORE" "$AFTER" \
    && ok "a quoted time already in the past is a bad read, not a booking" \
    || fail "a past quoted time must fall back to the flat window" "$(field 2)"
check_eq "…marked estimated" "$(field 4)" "estimated"

rm -f "$CODEX_STATE"; BEFORE="$(date +%s)"
sb 'codex_limit_record "$MSG_FAR"'
AFTER="$(date +%s)"
flat_window "$(field 2)" "$BEFORE" "$AFTER" \
    && ok "a quoted time beyond the week cap falls back too" \
    || fail "an absurd quoted time must fall back to the flat window" "$(field 2)"
check_eq "…marked estimated" "$(field 4)" "estimated"

rm -f "$CODEX_STATE"; BEFORE="$(date +%s)"
sb 'codex_limit_record "$MSG_TRUNC"'
AFTER="$(date +%s)"
flat_window "$(field 2)" "$BEFORE" "$AFTER" \
    && ok "a clause cut off mid-time never half-parses" \
    || fail "a truncated clause must fall back to the flat window" "$(field 2)"
check_eq "…marked estimated" "$(field 4)" "estimated"

echo
echo "the shell recorder — the clause appearing twice still parses:"
rm -f "$CODEX_STATE"
sb 'codex_limit_record "$MSG_REPORTED $MSG_REPORTED"'
check_eq "the doubled sentence records the quoted epoch" "$(field 2)" "$TARGET_EPOCH"
check_eq "…marked reported" "$(field 4)" "reported"
rm -f "$CODEX_STATE"
sb 'codex_limit_record "$MSG_MIXED"'
check_eq "a truncated first clause does not hide the complete second one" \
    "$(field 2)" "$TARGET_EPOCH"
check_eq "…marked reported" "$(field 4)" "reported"

echo
echo "an expired four-field line no longer benches anything:"
printf 'blocked-until\t%s\told refusal\treported\n' "$(( $(date +%s) - 60 ))" > "$CODEX_STATE"
sb 'codex_limit_until' >/dev/null \
    && fail "an expired line must not cool" "$(cat "$CODEX_STATE")" \
    || ok "codex_limit_until ignores an expired reported line"
check "codex_available answers yes again" sb 'codex_available'

echo
echo "the python recorder — lib/memory.py mirrors the same rule:"
if [ -x "${MEMORY_PYTHON:-}" ]; then
    PY_STATE="$SANDBOX/codex-state-py"
    OUT="$(env DESKCRAB_CODEX_STATE="$PY_STATE" "$MEMORY_PYTHON" - "$REPO/lib/memory.py" <<'EOF'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("deskcrab_memory", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
state = os.environ["DESKCRAB_CODEX_STATE"]

def rec(msg):
    try:
        os.unlink(state)
    except OSError:
        pass
    m.codex_limit_record(msg)
    with open(state) as f:
        parts = f.read().rstrip("\n").split("\t")
    return parts + ["MISSING"] * (4 - len(parts))

print("wild-parse", m.codex_limit_reset_parse(os.environ["WILD"]))
print("wild-want", int(time.mktime((2026, 9, 6, 22, 28, 0, 0, 0, -1))))

now = int(time.time())
p = rec(os.environ["MSG_REPORTED"])
print("rep-until", p[1])
print("rep-mark", p[3])
p = rec("You have hit your usage limit.")
print("flat-ok", now + 1800 <= int(p[1]) <= now + 1860, p[3])
p = rec(os.environ["MSG_PAST"])
print("past-ok", now + 1800 <= int(p[1]) <= now + 1860, p[3])
p = rec(os.environ["MSG_FAR"])
print("far-ok", now + 1800 <= int(p[1]) <= now + 1860, p[3])
p = rec(os.environ["MSG_TRUNC"])
print("trunc-ok", now + 1800 <= int(p[1]) <= now + 1860, p[3])
p = rec(os.environ["MSG_REPORTED"] + " " + os.environ["MSG_REPORTED"])
print("twice-until", p[1], p[3])
p = rec(os.environ["MSG_MIXED"])
print("mixed-until", p[1], p[3])

rec(os.environ["MSG_REPORTED"])
print("cooling", m.codex_cooling_until())
with open(state, "w") as f:
    f.write("blocked-until\t%d\told refusal\treported\n" % (now - 60))
print("expired", m.codex_cooling_until())
EOF
)"
    pyv() { printf '%s\n' "$OUT" | awk -v k="$1" '$1 == k {sub(/^[^ ]+ /, ""); print; exit}'; }
    check_eq "the wild sentence parses to the same epoch in python" \
        "$(pyv wild-parse)" "$(pyv wild-want)"
    check_eq "…which is the shell's answer too" "$(pyv wild-parse)" "$WILD_EPOCH"
    check_eq "the reported expiry is the quoted epoch" "$(pyv rep-until)" "$TARGET_EPOCH"
    check_eq "…marked reported" "$(pyv rep-mark)" "reported"
    check_eq "no quoted time falls back, estimated" "$(pyv flat-ok)" "True estimated"
    check_eq "a past quoted time falls back, estimated" "$(pyv past-ok)" "True estimated"
    check_eq "beyond the week cap falls back, estimated" "$(pyv far-ok)" "True estimated"
    check_eq "a truncated clause falls back, estimated" "$(pyv trunc-ok)" "True estimated"
    check_eq "the doubled sentence records the quoted epoch" \
        "$(pyv twice-until)" "$TARGET_EPOCH reported"
    check_eq "truncated-then-complete records the quoted epoch" \
        "$(pyv mixed-until)" "$TARGET_EPOCH reported"
    check_eq "codex_cooling_until honours the standing four-field line" \
        "$(pyv cooling)" "$TARGET_EPOCH"
    check_eq "…and ignores an expired one" "$(pyv expired)" "None"
else
    fail "the memory venv interpreter is not available — the python recorder is unproven"
fi
