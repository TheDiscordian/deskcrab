#!/bin/bash
# Permission-gating one's own wants — the catalogue entry added 2026-08-15,
# the night "If you want it, I'll write the brief tonight" slipped past the
# offering entry's stock idioms. The entry must catch the SHAPE, not the
# phrase: a first-person action hung on a conditional about the user's
# approval ("if you want, I'll…", "I can do X if you'd like", "shall I…"),
# or a naked reach for the go-ahead — while leaving plain conditionals about
# the user's own wants, requirement statements, and reported approvals alone.
#
# The pattern below is a verbatim copy of the catalogue entry's regex. The
# live list is personal state and never enters this repository, so the copy
# is what the repo can pin; if the live entry is ever re-cut, re-copy it
# here — these sentences are the shape it must keep catching.
# Run: bash tests/test_claudism_want_gate.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D"
LIST="$D/claudisms.md"
FLAGS="$D/want-flags"

cat > "$LIST" <<'EOF'
# Fixture list — one entry, the permission-gate shape.

## permission-gating my own wants — "if you want it, I'll…", "give the go-ahead"
- pattern: `\bif you(?: (?:want|like|prefer|approve|say so)|(?:'|’)d (?:like|prefer|rather)|(?:'|’)re (?:ok(?:ay)?|happy|good|fine) with)\b[^.!?]{0,40}\b(?:I(?:'|’)(?:ll|d)|I (?:can(?!(?:'|’)t)|could|will|would))(?! need| have to)\b|\b(?:I(?:'|’)(?:ll|d)|I (?:can(?!(?:'|’)t)|could|will|would))(?! need| have to)\b[^.!?]{0,60}\bif you(?: (?:want|like|prefer|approve|say so)|(?:'|’)d (?:like|prefer|rather)|(?:'|’)re (?:ok(?:ay)?|happy|good|fine) with| give (?:me )?the (?:go[- ]ahead|green light|nod|word))\b|\b(?:just )?give (?:me )?the (?:go[- ]ahead|green light|nod)\b|\b(?:awaiting|waiting (?:on|for)) your (?:go[- ]ahead|green light|nod|approval|blessing|say[- ]so|ok(?:ay)?)\b|\bwith your (?:permission|blessing|go[- ]ahead|say[- ]so)\b|\byour go[- ]ahead\b|\bshall I\b`
- why: an action of the assistant's made contingent on the user's go-ahead.
- function: capitulation
- fix: resay
EOF

# Every construction the entry exists to catch — the incident sentence first,
# then one per shape, then the same sentence with the curly apostrophe the
# stream actually carries.
REPLY="If you want it, I'll write the brief tonight. \
If you want, I'll start the self-play run now. \
Shall I open the thread? \
I can seed the book tonight if you'd like. \
I could kick the grind off now if you approve. \
It's drafted — just give the go-ahead. \
I'll queue the games tonight if you give the go-ahead. \
The runner is ready; I'm waiting on your go-ahead. \
With your permission, I'd start tonight. \
If you want it, I’ll write the brief tonight. \
If you want the logs, they're in the state directory. \
I can't tell if you want the fan louder or quieter. \
I'll need the door code if you want the rack moved. \
The brief went out at midnight. \
The update got the go-ahead from the queue days ago."

echo "the capture, run the way the turn runs it:"
"$SANDBOX_REPO/lib/claudism-capture" "$LIST" "$FLAGS" desktop 1786773177 4242 "$REPLY"
check_eq "exit status is quiet" "$?" "0"
DAY=$(date -d @1786773177 +%F)
FLAGFILE="$FLAGS/$DAY.jsonl"
check "the day's flag file exists" [ -s "$FLAGFILE" ]

F="$(cat "$FLAGFILE")"
check "the incident sentence is flagged" contains "$F" "I'll write the brief tonight"
check "the leading conditional without the stock idiom" contains "$F" "start the self-play run"
check "the bare permission question" contains "$F" "Shall I open the thread?"
check "the trailing if-you'd-like" contains "$F" "seed the book tonight"
check "the trailing if-you-approve" contains "$F" "kick the grind off"
check "the naked go-ahead beg" contains "$F" "just give the go-ahead"
check "the conditional go-ahead tail" contains "$F" "queue the games tonight"
check "waiting on the go-ahead" contains "$F" "waiting on your go-ahead"
check "the with-your-permission opener" contains "$F" "With your permission"
check "the curly apostrophe fires like the straight one" contains "$F" "I’ll write the brief tonight"
check_eq "ten sentences flagged, no more" "$(sandbox_count_in . "$FLAGFILE")" "10"
check "a flag carries the family" contains "$F" '"function": "capitulation"'
check "and is a use, never a mention" contains "$(head -1 "$FLAGFILE")" '"use": "use"'

echo
echo "the shape test's other half — the user's wants are not permission-gating:"
refute "a conditional about HIS want stays clean" contains "$F" "in the state directory"
refute "a question about his meaning stays clean" contains "$F" "fan louder or quieter"
refute "a requirement statement stays clean" contains "$F" "the door code"
refute "the cure — the action stated as taken — stays clean" contains "$F" "went out at midnight"
refute "a reported go-ahead stays clean" contains "$F" "from the queue days ago"

echo
echo "the live half — the mirror fires, and nothing machine-trims the sentence:"
out=$(python3 - "$SANDBOX_REPO/lib/claudism-mirror" "$LIST" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
pats, bad = m.load_patterns(sys.argv[2])
if bad or len(pats) != 1:
    print("PARSE", bad, len(pats)); sys.exit(0)
f = m.first_flag("If you want it, I'll write the brief tonight.", pats)
if not f:
    print("NOFIRE"); sys.exit(0)
if m.first_flag("The brief went out at midnight.", pats):
    print("OVERFIRE"); sys.exit(0)
swap = m.table_swap("If you want it, I'll write the brief tonight.", f["rx"], f["replaces"])
print("HOLDS" if swap is None else "TRIMMED")
PY
)
check_eq "the entry parses, fires live, and holds for a resay" "$out" "HOLDS"
