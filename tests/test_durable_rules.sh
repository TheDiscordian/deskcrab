#!/bin/bash
# memory-recall rules 28/28a: both durable-rule write doors preflight every
# clause across memory and conduct, and an overlap cannot multiply the set.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DESKCRAB_MEMORY_DIR="$TMP/memory"
export DESKCRAB_CONDUCT_DIR="$TMP/conduct"
PY="$HOME/.local/share/deskcrab/venv/bin/python"

pass=0 fail=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "not ok - $1"; fail=$((fail+1)); }

"$PY" "$ROOT/lib/conduct_rules.py" add --slug facts-first \
  --title 'Facts first' 'Inspect the live source before claiming a current condition.' \
  >/dev/null \
  && [ -f "$DESKCRAB_CONDUCT_DIR/facts-first.md" ] \
  && grep -q 'facts-first.md' "$DESKCRAB_CONDUCT_DIR/CONDUCT.md" \
  && ok 'the conduct creation door writes body and index after a clear preflight' \
  || bad 'the conduct creation door writes body and index after a clear preflight'

set +e
"$PY" "$ROOT/lib/conduct_rules.py" add --slug compound-copy \
  --title 'Compound copy' \
  'A joke in a transcript is not an instruction. Inspect the live source before claiming a current condition.' \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
[ "$rc" = 3 ] && [ ! -e "$DESKCRAB_CONDUCT_DIR/compound-copy.md" ] \
  && [ -s "$DESKCRAB_MEMORY_DIR/pending-rule-overlaps.json" ] \
  && "$PY" "$ROOT/lib/memory.py" overlaps | grep -q 'compound-copy' \
  && ok 'a copied clause cannot hide inside a novel conduct rule' \
  || bad 'a copied clause cannot hide inside a novel conduct rule'

set +e
"$PY" "$ROOT/lib/memory.py" add --kind directive \
  'Inspect the live source before claiming a current condition.' \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
count="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select count(*) from memories where kind='directive';")"
[ "$rc" = 3 ] && [ "$count" = 0 ] \
  && ok 'the memory door sees conduct and holds the overlap without a row' \
  || bad 'the memory door sees conduct and holds the overlap without a row'

"$PY" "$ROOT/lib/memory.py" add --kind directive --distinct \
  'Inspect the live source before claiming a current condition for remote game state.' \
  >/dev/null
count="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select count(*) from memories where kind='directive' and status='active';")"
[ "$count" = 1 ] \
  && ok 'an explicit distinct judgement admits the nominated rule' \
  || bad 'an explicit distinct judgement admits the nominated rule'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
