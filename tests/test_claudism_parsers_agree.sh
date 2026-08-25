#!/bin/bash
# The claudism list has ONE declared shape and two readers: the mirror reads it
# before I speak, the capture reads it after. They are meant to be identical
# line for line, and twice today they were not — the backreference clause lived
# in one copy for three hours (ca1c488, then 1215df6). This test is the seam
# itself, MIN-34: the shared functions must agree as code, docstrings and
# comments aside, or the drift is a failure and not a follow-up.
# Run: bash tests/test_claudism_parsers_agree.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

for fn in load_patterns classify_use sentences; do
    out=$(python3 - "$SANDBOX_REPO/lib/claudism-capture" \
                    "$SANDBOX_REPO/lib/claudism-mirror" "$fn" <<'EOF'
import ast, sys

def body(path, name):
    tree = ast.parse(open(path).read())
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            stmts = list(node.body)
            # The mirror's copy carries a docstring the capture's does not;
            # prose about the seam is not drift in the seam.
            if (stmts and isinstance(stmts[0], ast.Expr)
                    and isinstance(stmts[0].value, ast.Constant)
                    and isinstance(stmts[0].value.value, str)):
                stmts = stmts[1:]
            return "\n".join(ast.dump(s, indent=1) for s in stmts)
    return ""

cap, mir, name = sys.argv[1], sys.argv[2], sys.argv[3]
a, b = body(cap, name), body(mir, name)
if not a or not b:
    print("MISSING")
elif a == b:
    print("AGREE")
else:
    print("DRIFT")
EOF
)
    check "the two parsers' $fn() is the same code" [ "$out" = AGREE ]
done

# And the clause that started this: a replacement holding a backreference is
# spliced literally, so it must be refused by BOTH readers, not just the one.
for f in claudism-capture claudism-mirror; do
    check "$f refuses a backreference replacement" \
        contains "$(cat "$SANDBOX_REPO/lib/$f")" 'if re.search(r"\\[0-9g]", m.group(2)):'
done

# --------------------------------------------------------------------------
# The drain entry, 2026-08-24. The user had raised the word three times —
# "the drain" as the spoken name for the night's thread work — and for a day
# the ban existed only as a sentence about the list: the assistant said the
# word itself was on the banned list, and no list held it. This block is the
# pin that keeps a ban from being claimed and not written: the entry must be
# on the list and must land in the borrowed-jargon family in EVERY reader of
# the one format — the capture, the mirror (the corpus scorer and the nightly
# classifier import that same half), the feed-forward and the nightly scan —
# with the same scope in its why: her speech only, which is all the list ever
# reads; in specs, job briefs and code the word is the system's own
# vocabulary and stays.
#
# The live list is personal state and never enters this repository, so on a
# box that has one it is the subject, read-only; anywhere else the verbatim
# copy below is the shape the repo can pin — the want-gate convention.
echo
echo "the drain entry: on the list, one family, all four readers:"
DLIST="$SANDBOX/drain-list.md"
if [ -f "$SANDBOX_LIVE_DATA/claudisms.md" ]; then
    DLIST="$SANDBOX_LIVE_DATA/claudisms.md"
    echo "  (against the live list itself, read-only)"
else
    cat > "$DLIST" <<'EOF'
## "the drain" — borrowed jargon for the night's thread work
- pattern: `\bdrain\b`
- why: plumbing noun doing duty as the name of the night's thread work, in her mouth, to the user. Banned in her speech only, which is all this list ever reads: in specs, job briefs and code "the nightly drain" is deskcrab's own vocabulary, correct and untouched. Say the work, not the pipe — the night's thread work, the overnight queue.
- replace: `\b[Tt]onight's drain\b` -> `tonight's work`
- replace: `\b[Tt]he drain\b` -> `my sleep`
- replace: `\bdrains?\b` -> `sleep`
- function: borrowed-jargon
- fix: resay
EOF
fi
check "the word drain is on the list at all" grep -qi drain "$DLIST"

DSENT="The drain finished before dawn."
DEPOCH="$(date +%s)"
DDAY="$(date +%F)"
DFLAGS="$SANDBOX/drain-flags"
TAB="$(printf '\t')"

"$SANDBOX_REPO/lib/claudism-capture" "$DLIST" "$DFLAGS" desktop "$DEPOCH" 4243 "$DSENT"
DF="$(cat "$DFLAGS/$DDAY.jsonl" 2>/dev/null)"
check "the capture files it under borrowed-jargon" \
    contains "$DF" '"function": "borrowed-jargon"'
check "as a use, never a mention" contains "$DF" '"use": "use"'

out=$(python3 - "$SANDBOX_REPO/lib/claudism-mirror" "$DLIST" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
pats, _bad = m.load_patterns(sys.argv[2])
f = m.first_flag("The drain finished before dawn.", pats)
if not f:
    print("NOFIRE"); sys.exit(0)
if f.get("function") != "borrowed-jargon" or f.get("fix") != "resay":
    print("WRONGFAMILY %s %s" % (f.get("function"), f.get("fix"))); sys.exit(0)
e = [p for p in pats if p["pat"] == f["pattern"]][0]
if "speech" not in e["why"] or "specs, job briefs and code" not in e["why"]:
    print("NOSCOPE"); sys.exit(0)
swap = m.table_swap("The drain finished before dawn.", f["rx"], f["replaces"])
print("HOLDS" if swap is None else "TRIMMED:" + swap)
PY
)
# This assertion expected HOLDS until 2026-08-25, and holding was wrong: a
# hold hands the line to the mirror, which repairs the TEXT after the
# streamer has already spoken the original aloud. The entry carries replace
# lines now, so the table swaps the sentence before the voice reaches it.
check_eq "the mirror fires it live — same family, resay, the scope in the why, and the table swaps it before the voice reaches it" \
    "$out" "TRIMMED:My sleep finished before dawn."

DOUT="$(CLAUDISM_FLAGS_DIR="$DFLAGS" CLAUDISM_LIST="$DLIST" \
    "$SANDBOX_REPO/lib/claudism-feedforward")"
check "the feed-forward names it by the same family" \
    contains "$DOUT" "(the borrowed-jargon move)"
check "and quotes the line as said" contains "$DOUT" "$DSENT"

DJ="$SANDBOX/drain-journal"
DOUTDIR="$SANDBOX/drain-claudisms"
mkdir -p "$DJ"
printf '{"epoch": %s, "time": "%s", "kind": "desktop", "pid": 4243, "user": "?", "reply": "%s"}\n' \
    "$DEPOCH" "$(date -d "@$DEPOCH" +%Y-%m-%dT%H:%M:%S%z)" "$DSENT" > "$DJ/$DDAY.jsonl"
cat > "$SANDBOX/drain-crab" <<'CRAB'
#!/bin/bash
exit 0
CRAB
chmod +x "$SANDBOX/drain-crab"
CRAB_BIN="$SANDBOX/drain-crab" DAY_JOURNAL_DIR="$DJ" CLAUDISM_LIST="$DLIST" \
    CLAUDISM_DIR="$DOUTDIR" CLAUDISM_FLAGS_DIR="$SANDBOX/drain-scan-flags" \
    CLAUDISM_REWRITES=0 "$SANDBOX_REPO/lib/claudism-scan" run "$DDAY" >/dev/null 2>&1
check "the nightly scan scores it under the same family" \
    contains "$(cat "$DOUTDIR/functions.tsv" 2>/dev/null)" \
    "${DDAY}${TAB}borrowed-jargon${TAB}1${TAB}0"
check "and counts it under its own key" \
    contains "$(cat "$DOUTDIR/counts.tsv" 2>/dev/null)" \
    "${TAB}the-drain${TAB}1"
