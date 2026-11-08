#!/usr/bin/env bash
# The query recall-block composes inside a REAL prompt build — nothing typed,
# nothing stubbed in the path under test.
#
# The open item behind this (2026-08-07 12:58): every check of the composed-
# query fix went through `crab memory search`, which takes a query someone
# typed, and the path that actually runs — recall-block composing the query
# itself inside build_system_prompt — was never exercised end to end. Its
# sibling test, tests/test_recall_composition.sh, closed most of that gap but
# still replaces lib/memory.py with a recording stub; a drift between the stub's
# call and cmd_recall_block's own would never be seen there. Here NOTHING is
# replaced: the real `crab remote` and the real `crab wake` drive the real
# lib/common.sh into the shipped `memory.py recall-block`, and the composed
# query is read at the embedder's own doorstep — a recording stand-in
# listening at MEMORY_EMBED_URL (an existing knob, not a capture added for the
# test), answering the shape ollama would and writing down what it was asked.
# The store is the sandbox's own empty scratch store; the daemon is never
# needed, so the test is offline and deterministic.
#
# What is pinned (specs/memory-recall.md rules 2-5 and 7-9):
#   (a) a conversation build composes from the conversation tail — the user's
#       last turn first, holding the weighted share, her preceding reply behind
#       it — and carries not one word of the wants shelf, even while a want is
#       fresh in hand;
#   (b) an autonomous wake build carries its reason, the ONE want being worked
#       (its shelf line and its most recent dated section), and never the rest
#       of the shelf or the document's history;
#   (c) the length cap is hard on BOTH shapes, a segment exactly the size of
#       the budget is within the budget (rule 9 — MAJ-22's boundary), and every
#       bite is named in the recall log through the --log path lib/common.sh
#       actually wires. A build that cut nothing logs nothing.
#
# Run: bash tests/test_recall_query_composition.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# The store opens through sqlite-vec, which lives in the venv the sandbox
# already points MEMORY_PYTHON at. No interpreter, no store, no test.
[ -n "${MEMORY_PYTHON:-}" ] && [ -x "${MEMORY_PYTHON:-}" ] \
    || sandbox_skip "the memory venv interpreter is not available (sqlite-vec)"

WORK="$SANDBOX/work"
mkdir -p "$WORK"
RECALL_LOG="$DESKCRAB_STATE_PREFIX-memory-recall.log"
CONVO="$DESKCRAB_STATE_PREFIX-convo.txt"

# --- the embedder's doorstep, recording --------------------------------------
# Answers /api/embed exactly as ollama would (an embeddings list of the right
# dimension), records every input it was asked about, embeds nothing.
cat > "$WORK/embed-recorder.py" <<'EOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

workdir = sys.argv[1]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        inputs = body.get("input") or []
        if isinstance(inputs, str):
            inputs = [inputs]
        for text in inputs:
            prefix, _, rest = text.partition(": ")
            with open(os.path.join(workdir, "asked-prefix.txt"), "w") as f:
                f.write(prefix)
            with open(os.path.join(workdir, "asked.txt"), "w") as f:
                f.write(rest)
            with open(os.path.join(workdir, "asked-count.txt"), "a") as f:
                f.write("asked\n")
        out = json.dumps({"embeddings": [[0.1] * 768 for _ in inputs]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(workdir, "embed.port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
EOF
python3 "$WORK/embed-recorder.py" "$WORK" &
RECORDER_PID=$!
sandbox_at_exit "kill $RECORDER_PID"
for _ in $(seq 1 50); do [ -s "$WORK/embed.port" ] && break; sleep 0.1; done
[ -s "$WORK/embed.port" ] || die "the recording embedder never came up"
export MEMORY_EMBED_URL="http://127.0.0.1:$(cat "$WORK/embed.port")/api/embed"

asked() { cat "$WORK/asked.txt" 2>/dev/null; }
asked_len() { wc -c < "$WORK/asked.txt" 2>/dev/null || echo 0; }
asked_reset() { rm -f "$WORK/asked.txt" "$WORK/asked-prefix.txt" "$WORK/asked-count.txt"; }
trunc_lines() { sandbox_count_in TRUNCATED "$RECALL_LOG"; }

# The budgets, from the shipped module rather than a copy that can drift.
read -r CAP USER_CAP <<<"$("$MEMORY_PYTHON" - "$SANDBOX_REPO/lib/memory.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.RECALL_QUERY_CHARS, int(m.RECALL_QUERY_CHARS * m.RECALL_USER_SHARE))
EOF
)"
[ -n "$CAP" ] && [ "$CAP" -gt 0 ] || die "could not read the budgets from lib/memory.py"

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=1
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
EOF

# A shelf with a distinctive topic beside another, and a want document whose
# CURRENT dated note is distinguishable from its founding one. pipeorgan.md is
# freshly written — a want genuinely in hand (inside WANT_RECENT_SECS) — which
# makes the conversation case the strong claim: even NOW, no wants in his query.
mkdir -p "$WORK/wants"
cat > "$WORK/wants.md" <<'EOF'
# Wants

- 🎼 **ORGAN_SHELF_TOPIC — sit at the pipe organ** — a sitting at 21:20, daily. → `wants/pipeorgan.md`
- 🚩 **SEMAPHORE_OTHER_WANT — the flag drill** — measured it once. → `wants/semaphore.md`
EOF
cat > "$WORK/wants/pipeorgan.md" <<'EOF'
# Pipe organ

## What I want

To play it.

## 2026-08-05 — the founding entry

ANCIENT_HISTORY_MARKER — how this began, which is history, and history dilutes.

## 2026-08-14 — where it stands

CURRENT_PROGRESS_MARKER — pedal exercises, hands and feet together.
EOF
printf '# Semaphore\n\n## 2026-08-01 — old\n\nSEMAPHORE_DOC_MARKER\n' > "$WORK/wants/semaphore.md"
touch -d '2026-08-01' "$WORK/wants/semaphore.md"

echo "(a) a conversation asks about the conversation — the tail, weighted, no wants:"
cat > "$CONVO" <<'EOF'
User [11:58]: could you check what the calendar holds tomorrow
Assistant [11:59]: PREV_REPLY_MARKER — the clinic said they would call back on Thursday.

EOF
asked_reset
"$SANDBOX_REPO/crab" remote "what did the doctor say about my knee KNEE_TURN_MARKER" >/dev/null 2>&1 || true
[ -s "$WORK/asked.txt" ] || die "the remote turn never asked the embedder anything — recall-block did not compose"
Q="$(asked)"
check_eq "the store was asked exactly once for the build" \
    "$(sandbox_count_in asked "$WORK/asked-count.txt")" "1"
check_eq "and asked as a query, with the query prefix" \
    "$(cat "$WORK/asked-prefix.txt" 2>/dev/null)" "search_query"
check "the user's last turn is the subject" contains "$Q" "KNEE_TURN_MARKER"
check "her preceding reply rides behind it as context" contains "$Q" "PREV_REPLY_MARKER"
FIRST="$(head -n1 "$WORK/asked.txt")"
check "the user's turn holds the first line" contains "$FIRST" "KNEE_TURN_MARKER"
refute "and the reply stays behind it, never ahead of it" contains "$FIRST" "PREV_REPLY_MARKER"
for marker in ORGAN_SHELF_TOPIC SEMAPHORE_OTHER_WANT CURRENT_PROGRESS_MARKER \
              ANCIENT_HISTORY_MARKER wants/; do
    refute "no wants text in a conversation query ('$marker')" contains "$Q" "$marker"
done
check_eq "a build that cut nothing logged nothing" "$(trunc_lines)" "0"

echo
echo "(b) a wake asks about the one want in hand — shelf line, current note, nothing else:"
asked_reset
"$SANDBOX_REPO/crab" wake scheduled "sit with the organ scores — wants/pipeorgan.md" >/dev/null 2>&1 || true
[ -s "$WORK/asked.txt" ] || die "the wake never asked the embedder anything — recall-block did not compose"
WQ="$(asked)"
check_eq "the store was asked exactly once for the build" \
    "$(sandbox_count_in asked "$WORK/asked-count.txt")" "1"
check "the wake's reason is the query's subject" contains "$WQ" "sit with the organ scores"
check "the named want's shelf line is there" contains "$WQ" "ORGAN_SHELF_TOPIC"
check "and its most recent dated section" contains "$WQ" "CURRENT_PROGRESS_MARKER"
refute "the founding entry stays home — history dilutes the query" \
    contains "$WQ" "ANCIENT_HISTORY_MARKER"
refute "the rest of the shelf stays home" contains "$WQ" "SEMAPHORE_OTHER_WANT"
check "a wake query sits inside the budget ($(asked_len) of $CAP)" \
    [ "$(asked_len)" -le "$CAP" ]
check_eq "still nothing logged — nothing was cut" "$(trunc_lines)" "0"

echo
echo "(c) the cap is hard on a conversation, and the bite is named, never swallowed:"
cat > "$CONVO" <<'EOF'
User [12:10]: how long until the ligament heals
Assistant [12:11]: CONTEXT_REPLY_MARKER — the specialist said six weeks with the brace on.

EOF
LONG="$(python3 -c 'print("LONGTURN_MARKER " + "the specialist walked the whole ligament recovery plan " * 160)')"
asked_reset
"$SANDBOX_REPO/crab" remote "$LONG" >/dev/null 2>&1 || true
[ -s "$WORK/asked.txt" ] || die "the over-long remote turn never asked the embedder anything"
check "the composed query is clipped to the budget ($(asked_len) of $CAP)" \
    [ "$(asked_len)" -le "$CAP" ]
FIRST_LEN="$(( $(head -n1 "$WORK/asked.txt" | wc -c) - 1 ))"
check "the user's turn is cut to its weighted share, not the whole budget ($FIRST_LEN of $USER_CAP)" \
    [ "$FIRST_LEN" -le "$USER_CAP" ]
check "and the share genuinely bit — the turn fills it" \
    [ "$FIRST_LEN" -ge $(( USER_CAP - 60 )) ]
check "what was kept still opens with his words" \
    contains "$(head -c 60 "$WORK/asked.txt")" "LONGTURN_MARKER"
check "and the clip spared the context behind it" contains "$(asked)" "CONTEXT_REPLY_MARKER"
check_eq "one cut, one TRUNCATED line" "$(trunc_lines)" "1"
check "the log names the conversation shape" \
    grep -q "TRUNCATED conversation query" "$RECALL_LOG"
check "and names the bite — the user turn, true size to weighted share" \
    grep -qE "user turn [0-9]+->$USER_CAP" "$RECALL_LOG"

echo
echo "(c) the cap is hard on a wake, and a budget-sized segment is WITHIN the budget (rule 9):"
# No spaces after the marker, on purpose: the clip at the budget lands mid-word,
# rstrip removes nothing, and the kept reason is EXACTLY budget-sized — the
# boundary MAJ-22 named, where an exclusive comparison throws the whole agenda
# away and composes an empty query from the longest agendas only.
LONGREASON="$(python3 -c 'print("LONGREASON_MARKER " + "shelfdrawerledgerfoliocatalogue" * 300)')"
asked_reset
"$SANDBOX_REPO/crab" wake scheduled "$LONGREASON" >/dev/null 2>&1 || true
[ -s "$WORK/asked.txt" ] || die "the over-long wake composed an empty query — the whole agenda was thrown away (MAJ-22)"
check_eq "the reason is kept AT the budget, exactly, not discarded over a joining newline" \
    "$(asked_len)" "$CAP"
check "what was kept opens with the agenda" \
    contains "$(head -c 60 "$WORK/asked.txt")" "LONGREASON_MARKER"
check_eq "a second cut, a second TRUNCATED line" "$(trunc_lines)" "2"
check "the log names the wake shape" grep -q "TRUNCATED wake query" "$RECALL_LOG"
check "and names the bite — the wake reason, true size to the budget" \
    grep -qE "wake reason [0-9]+->$CAP" "$RECALL_LOG"
