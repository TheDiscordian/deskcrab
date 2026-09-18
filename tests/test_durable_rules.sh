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

# Rule 28b: the stored set reconciles through the same CLI. A judged
# duplicate pair merges into one survivor with provenance kept ...
"$PY" "$ROOT/lib/memory.py" add --kind directive --distinct \
  'Inspect the live source before you claim any current remote game condition.' \
  >/dev/null
keep="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select min(id) from memories where kind='directive' and status='active';")"
dup="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select max(id) from memories where kind='directive' and status='active';")"
"$PY" "$ROOT/lib/memory.py" merge --into "$keep" "$dup" >/dev/null
active="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select count(*) from memories where kind='directive' and status='active';")"
link="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select status || ':' || superseded_by from memories where id=$dup;")"
[ "$active" = 1 ] && [ "$link" = "superseded:$keep" ] \
  && ok 'memory merge absorbs a judged duplicate, provenance kept' \
  || bad 'memory merge absorbs a judged duplicate, provenance kept'

# ... and a stored later correction is linked, newer row authoritative.
"$PY" "$ROOT/lib/memory.py" add --kind directive --distinct \
  'Night dispatch happens after his usual bedtime hour.' >/dev/null
old="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select max(id) from memories;")"
"$PY" "$ROOT/lib/memory.py" add --kind directive --distinct \
  'Correction: night dispatch waits for the machine to be idle, not for a clock hour.' \
  >/dev/null
new="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select max(id) from memories;")"
set +e
"$PY" "$ROOT/lib/memory.py" supersede "$old" "$new" >/dev/null 2>&1
swapped=$?
set -e
"$PY" "$ROOT/lib/memory.py" supersede "$new" "$old" >/dev/null
row="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select status || ':' || superseded_by from memories where id=$old;")"
newstat="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select status || ':' || supersedes from memories where id=$new;")"
[ "$swapped" != 0 ] && [ "$row" = "superseded:$new" ] && [ "$newstat" = "active:$old" ] \
  && ok 'memory supersede keeps the newer correction authoritative and refuses swapped arguments' \
  || bad 'memory supersede keeps the newer correction authoritative and refuses swapped arguments'

# Rule 28c: a stored FACT is correctable too, within its own kind. The decay
# pass is keyed on disuse and rule 12 clamps every other factor into a
# five-percent band, so a note that is wrong and useful outlives every rule
# written about how to read it.
"$PY" "$ROOT/lib/memory.py" add --kind note \
  'The running tally stands at five wins to eight losses.' >/dev/null
oldnote="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" "select max(id) from memories;")"
"$PY" "$ROOT/lib/memory.py" add --kind note \
  'Recounted from the source files: the running tally is twenty-nine to thirty-seven.' \
  >/dev/null
newnote="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" "select max(id) from memories;")"
"$PY" "$ROOT/lib/memory.py" supersede "$newnote" "$oldnote" >/dev/null
noterow="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select status || ':' || superseded_by from memories where id=$oldnote;")"
[ "$noterow" = "superseded:$newnote" ] \
  && ok 'memory supersede corrects a stored note, not only a stored rule' \
  || bad 'memory supersede corrects a stored note, not only a stored rule'

# ... but never across kinds: a fact the assistant minted must not be able to
# retire a rule the user set.
set +e
"$PY" "$ROOT/lib/memory.py" supersede "$newnote" "$new" >/dev/null 2>&1
crosskind=$?
"$PY" "$ROOT/lib/memory.py" add --kind observation \
  'One night of unusually quiet autonomous work.' >/dev/null
obs="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" "select max(id) from memories;")"
"$PY" "$ROOT/lib/memory.py" supersede "$obs" "$newnote" >/dev/null 2>&1
obsrc=$?
set -e
obsstat="$(sqlite3 "$DESKCRAB_MEMORY_DIR/memory.db" \
  "select status from memories where id=$newnote;")"
[ "$crosskind" != 0 ] && [ "$obsrc" != 0 ] && [ "$obsstat" = active ] \
  && ok 'memory supersede refuses across kinds and refuses observations outright' \
  || bad 'memory supersede refuses across kinds and refuses observations outright'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
