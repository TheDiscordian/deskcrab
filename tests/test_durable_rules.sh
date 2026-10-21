#!/bin/bash
# memory-recall rules 28/28a: both durable-rule write doors preflight every
# clause across memory and conduct, and an overlap cannot multiply the set.
# Both doors declare their writes through `~/.local/bin/crab touching`; inside
# the sandbox that path is a stub in the scratch home, so no declaration ever
# reaches the live watcher. Run: bash tests/test_durable_rules.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u
ROOT="$SANDBOX_REPO"
TMP="$SANDBOX/durable"
mkdir -p "$TMP" "$HOME/.local/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/touching-calls"\n' "$TMP" > "$HOME/.local/bin/crab"
chmod +x "$HOME/.local/bin/crab"
export DESKCRAB_MEMORY_DIR="$TMP/memory"
export DESKCRAB_CONDUCT_DIR="$TMP/conduct"
PY="${MEMORY_PYTHON:-python3}"
"$PY" -c 'import sqlite_vec' 2>/dev/null \
    || sandbox_skip "no sqlite-vec interpreter (MEMORY_PYTHON) on this box"

bad() { fail "$1"; }

"$PY" "$ROOT/lib/conduct_rules.py" add --slug facts-first \
  --title 'Facts first' 'Inspect the live source before claiming a current condition.' \
  >/dev/null \
  && [ -f "$DESKCRAB_CONDUCT_DIR/facts-first.md" ] \
  && grep -q 'facts-first.md' "$DESKCRAB_CONDUCT_DIR/CONDUCT.md" \
  && ok 'the conduct creation door writes body and index after a clear preflight' \
  || bad 'the conduct creation door writes body and index after a clear preflight'

# Rule 28a's other door: retiring takes the index line and the body out in
# the same act, the body kept under archive/ with the reason.
"$PY" "$ROOT/lib/conduct_rules.py" add --slug retire-me \
  --title 'Retire me' --distinct 'Hum quietly while the kettle boils on Thursdays.' >/dev/null
"$PY" "$ROOT/lib/conduct_rules.py" retire retire-me 'the kettle is gone' >/dev/null \
  && [ ! -e "$DESKCRAB_CONDUCT_DIR/retire-me.md" ] \
  && ! grep -q 'retire-me.md' "$DESKCRAB_CONDUCT_DIR/CONDUCT.md" \
  && grep -q 'facts-first.md' "$DESKCRAB_CONDUCT_DIR/CONDUCT.md" \
  && grep -q 'Retired .*: the kettle is gone' "$DESKCRAB_CONDUCT_DIR"/archive/retire-me-*.md \
  && grep -q 'Hum quietly' "$DESKCRAB_CONDUCT_DIR"/archive/retire-me-*.md \
  && ok 'retiring takes the index line and the body out together, the body archived with its reason' \
  || bad 'retiring takes the index line and the body out together, the body archived with its reason'
"$PY" "$ROOT/lib/conduct_rules.py" add --slug retire-me \
  --title 'Retire me' --distinct 'Hum quietly while the kettle boils on Thursdays.' >/dev/null
"$PY" "$ROOT/lib/conduct_rules.py" retire retire-me 'gone again' >/dev/null
[ "$(ls "$DESKCRAB_CONDUCT_DIR"/archive/retire-me-*.md | wc -l)" = 2 ] \
  && grep -q 'the kettle is gone' "$DESKCRAB_CONDUCT_DIR"/archive/retire-me-*.md \
  && ok 'a slug retired twice never overwrites the body archived the first time' \
  || bad 'a slug retired twice never overwrites the body archived the first time'
set +e
"$PY" "$ROOT/lib/conduct_rules.py" retire no-such-rule 'nothing' >/dev/null 2>&1
rc=$?
"$PY" "$ROOT/lib/conduct_rules.py" retire facts-first >/dev/null 2>&1
rc2=$?
set -e
[ "$rc" != 0 ] && [ "$rc2" != 0 ] && [ -f "$DESKCRAB_CONDUCT_DIR/facts-first.md" ] \
  && ok 'retire refuses an unknown rule and a missing reason, and touches nothing' \
  || bad 'retire refuses an unknown rule and a missing reason, and touches nothing'

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

check "every write declaration went to the scratch home's crab, never the live one" \
    grep -q '^touching ' "$TMP/touching-calls"

# Filing-only fault and race cases use a cheap preflight double. The real
# semantic preflight is exercised above; these children still execute the
# actual conduct command and write only in this sandbox's conduct drawer.
cat > "$TMP/filing-probe.py" <<'PY'
import builtins, importlib.util, os, sys, time, types
from datetime import datetime
from pathlib import Path

memory = types.ModuleType('memory')
class Store:
    def __init__(self, *args): pass
    def rule_overlaps(self, *args): return []
    def resolve_rule_overlap(self, *args): pass
memory.Store = Store
memory.default_dir = lambda: os.environ['DESKCRAB_MEMORY_DIR']
sys.modules['memory'] = memory
spec = importlib.util.spec_from_file_location('conduct_probe', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class FixedClock:
    @classmethod
    def now(cls): return datetime(2030, 1, 1).astimezone()
module.datetime = FixedClock
original = builtins.open
def guarded_open(path, mode='r', *args, **kwargs):
    if os.environ.get('FAIL_INDEX_READ') and Path(path).name == 'CONDUCT.md' and 'r' in mode:
        raise PermissionError('injected index read refusal')
    return original(path, mode, *args, **kwargs)
builtins.open = guarded_open
read_index = module.read_index
def slow_index(*args):
    lines = read_index(*args)
    time.sleep(0.05)  # Force concurrent readers to overlap without the lock.
    return lines
module.read_index = slow_index
sys.argv = ['conduct', *sys.argv[2:]]
sys.exit(module.main())
PY
filing_rc=0
"$PY" - "$ROOT/lib/conduct_rules.py" "$TMP/filing-probe.py" "$TMP/filing" <<'PY' || filing_rc=$?
import os, subprocess, sys
from pathlib import Path
source, probe, root = sys.argv[1], sys.argv[2], Path(sys.argv[3])
root.mkdir()
index = root / 'CONDUCT.md'
index.write_text('# Conduct\n\n- Keep → `keep.md`\n- Victim → `victim.md`\n')
(root / 'keep.md').write_text('Keep this exact body.\n')
(root / 'victim.md').write_text('Version zero.\n')
env = dict(os.environ, DESKCRAB_CONDUCT_DIR=str(root))
def run(*args, fault=False):
    return subprocess.run([sys.executable, probe, source, *args],
                          env=dict(env, **({'FAIL_INDEX_READ': '1'} if fault else {})),
                          capture_output=True, text=True, timeout=20)
def add(slug, text):
    return ['add', '--slug', slug, '--title', slug, '--distinct', text]
before = {p.name: p.read_bytes() for p in root.glob('*.md')}
for args in (add('fault-new', 'Must not be half-filed.'), ['retire', 'victim', 'retire it']):
    result = run(*args, fault=True)
    assert result.returncode != 0 and 'index read refusal' in result.stderr, result
    assert {p.name: p.read_bytes() for p in root.glob('*.md')} == before
assert not (root / 'archive').exists()
print('read refusal preserved every body and index byte')

# One retirement and six adds race against the same read/modify/write index.
commands = [add(f'rule-{letter}', f'Rule {letter}.') for letter in 'abcdef']
commands.append(['retire', 'victim', 'version zero retired'])
children = [subprocess.Popen([sys.executable, probe, source, *args], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for args in commands]
try:
    for child in children:
        output, error = child.communicate(timeout=20)
        assert child.returncode == 0, (output, error)
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
            child.wait()
text = index.read_text()
assert '`keep.md`' in text and '`victim.md`' not in text
for letter in 'abcdef':
    assert text.count(f'`rule-{letter}.md`') == 1, text
    assert (root / f'rule-{letter}.md').is_file()
assert not (root / 'victim.md').exists()
print('concurrent add/retire kept all six new pairs and the unrelated rule')

# The injected clock makes all three retirements reserve the same base name.
for version in ('one', 'two'):
    assert run(*add('victim', f'Version {version}.')).returncode == 0
    assert run('retire', 'victim', f'version {version} retired').returncode == 0
archived = sorted((root / 'archive').glob('victim-20300101-000000*.md'))
assert len(archived) == 3, archived
for version in ('zero', 'one', 'two'):
    assert any(f'Version {version}.' in p.read_text() for p in archived)
print('same-second slug reuse preserved all three archived bodies')
PY
check_eq "read faults refuse both doors untouched; concurrent filing loses no pair; archive collisions retain every body" "$filing_rc" 0
