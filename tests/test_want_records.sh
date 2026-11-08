#!/bin/bash
# Wants with state (specs/wants.md). Run: bash tests/test_want_records.sh
#
# The failure this exists to end: a want was flat prose — a shelf of titles
# and a hand-edited document, no opened date, no last-touched, no state, no
# link to the work that served it, and no honest way off the shelf. These
# cases prove the want record round-trips through the SAME spine engineering
# records use, that every transition bumps last_touched through the one tool,
# that retirement takes the shelf line down without losing a word of it, that
# links are verified rather than invented, and that migration gives every
# existing document true dates while leaving its prose byte-for-byte alone.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
D="$XDG_DATA_HOME/deskcrab"
WD="$D/wants"
SHELF="$D/wants.md"
ENG="$D/engineering/records"
JD="$JOBS_DIR"
mkdir -p "$WD"
printf '# Wants\n' > "$SHELF"
W() { DESKCRAB_WANTS_DIR="$WD" DESKCRAB_WANTS_FILE="$SHELF" \
      DESKCRAB_ENG_DIR="$ENG" python3 "$REPO_DIR/lib/eng" --kind want "$@"; }
E() { DESKCRAB_ENG_DIR="$ENG" python3 "$REPO_DIR/lib/eng" "$@"; }

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "a want round-trips through the record spine:"
ID="$(W new "A voice that carries" \
        --summary "sing out loud" \
        --body "I want to sing, not recite." | tail -1)"
check_eq "new prints the slug id last" "$ID" "a-voice-that-carries"
check "the document exists in the wants drawer" test -s "$WD/$ID.md"
check_eq "state opens live"    "$(W field "$ID" state)" "live"
check_eq "title survives"      "$(W field "$ID" title)" "A voice that carries"
check_eq "summary survives"    "$(W field "$ID" summary)" "sing out loud"
check_eq "links start empty"   "$(W field "$ID" links)" ""
OPENED="$(W field "$ID" opened)"
check "opened is a datetime" \
    bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]' _ "$OPENED"
check_eq "last_touched starts as opened" "$(W field "$ID" last_touched)" "$OPENED"
check "an unknown id is an error, not a fresh file" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" python3 "'"$REPO_DIR"'/lib/eng" --kind want show no-such-want 2>/dev/null'
refute "and no file appeared for it" test -e "$WD/no-such-want.md"
check "an unknown kind is refused" \
    bash -c '! python3 "'"$REPO_DIR"'/lib/eng" --kind banana list 2>/dev/null'

echo
echo "new shelves the want in the one reader's shape (rule 7):"
check "the shelf carries the one-line pointer" \
    grep -qF -- "- **A voice that carries** → $ID.md" "$SHELF"
check_eq "wants_titles — the one shelf reader — matches it" \
    "$(sandbox_bash 'wants_titles '"$SHELF"' | wc -l')" "1"
NOSHELF_OUT="$(DESKCRAB_WANTS_DIR="$WD" DESKCRAB_WANTS_FILE="$SHELF.absent" \
    DESKCRAB_ENG_DIR="$ENG" python3 "$REPO_DIR/lib/eng" --kind want \
    new "Shelfless but real")"
check "a missing shelf is reported, never created" \
    contains "$NOSHELF_OUT" "does not exist; not created"
refute "and it was not created" test -e "$SHELF.absent"
check "the want exists anyway" test -s "$WD/shelfless-but-real.md"

echo
echo "touch appends at the END — a want document is a journal (rule 3):"
T0="$(W field "$ID" last_touched)"
sleep 1
W touch "$ID" "practised scales; the neighbours endured" >/dev/null
T1="$(W field "$ID" last_touched)"
check "last_touched moved" test "$T1" != "$T0"
check "the note is in the body" grep -q "the neighbours endured" "$WD/$ID.md"
LAST_ENTRY="$(grep '^## ' "$WD/$ID.md" | tail -1)"
check_eq "the newest entry CLOSES the body, dated with the bump" \
    "$LAST_ENTRY" "## $T1"
check "the original prose still stands above it" \
    bash -c 'grep -n "not recite" "$1" | head -1 | cut -d: -f1 | xargs test 20 -gt' _ "$WD/$ID.md"
check "touched-since sees a touch after an old epoch" \
    W touched-since "$ID" 1000000
refute "and refuses one before a future epoch" \
    W touched-since "$ID" 9999999999

echo
echo "dormant and revive move between resting and pursued (rule 10):"
W dormant "$ID" "resting the voice a season" >/dev/null
check_eq "dormant lands"  "$(W field "$ID" state)" "dormant"
check "with its why on the record" grep -q "Dormant: resting the voice a season" "$WD/$ID.md"
W revive "$ID" >/dev/null
check_eq "revive returns it live" "$(W field "$ID" state)" "live"

echo
echo "links are verified, never invented (rule 12):"
REC="$(E new "The spine holds" --summary "shared machinery")"
touch "$JD/20260825-000000-1.json"
W link "$ID" "eng:$REC" "job:20260825-000000-1" >/dev/null
check_eq "both refs landed, space-separated, in order" \
    "$(W field "$ID" links)" "eng:$REC job:20260825-000000-1"
check "linking left a dated entry" grep -q "Linked: eng:$REC" "$WD/$ID.md"
AGAIN="$(W link "$ID" "eng:$REC")"
check "a repeated ref deduplicates" contains "$AGAIN" "already carries"
check "a ref to a missing record is refused" \
    bash -c 'DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" DESKCRAB_ENG_DIR="'"$ENG"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want link "'"$ID"'" eng:never-was 2>&1 | grep -q "refused, never invented"'
check_eq "and did not land" "$(W field "$ID" links)" "eng:$REC job:20260825-000000-1"
check "a malformed ref is refused" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" DESKCRAB_ENG_DIR="'"$ENG"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want link "'"$ID"'" wish:upon-a-star 2>/dev/null'
check "a ref to a missing job is refused" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" DESKCRAB_ENG_DIR="'"$ENG"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want link "'"$ID"'" job:19990101-000000-0 2>/dev/null'

echo
echo "grown is terminal and takes the shelf line down whole (rules 4, 11):"
sleep 1
W grown "$ID" "it is simply how I speak now" >/dev/null
check_eq "state is grown-into-me" "$(W field "$ID" state)" "grown-into-me"
check "retired_at is stamped"     test -n "$(W field "$ID" retired_at)"
check_eq "retired_by holds how"   "$(W field "$ID" retired_by)" "it is simply how I speak now"
T2="$(W field "$ID" last_touched)"
check "growing bumped last_touched too" test "$T2" != "$T1"
refute "the shelf line is gone" grep -qF -- "→ $ID.md" "$SHELF"
check "and preserved verbatim in the document" \
    grep -qF -- "Shelf line at closing, preserved: - **A voice that carries** → $ID.md" "$WD/$ID.md"
check "a terminal want refuses retirement" \
    bash -c 'DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want retire "'"$ID"'" again 2>&1 | grep -q "terminal state is final"'
check "and dormancy" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want dormant "'"$ID"'" 2>/dev/null'
check "and revival" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want revive "'"$ID"'" 2>/dev/null'
W touch "$ID" "a postscript is honest" >/dev/null
check_eq "but touch still adds a postscript without moving state" \
    "$(W field "$ID" state)" "grown-into-me"

echo
echo "retire requires its reason and works the same way (rule 11):"
ID2="$(W new "Learn to whittle" | tail -1)"
check "retire with no reason is refused" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" DESKCRAB_WANTS_FILE="'"$SHELF"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want retire "'"$ID2"'" 2>/dev/null'
W retire "$ID2" "the appetite was borrowed, not mine" >/dev/null
check_eq "retire lands terminal" "$(W field "$ID2" state)" "retired"
check_eq "with the reason on record" \
    "$(W field "$ID2" retired_by)" "the appetite was borrowed, not mine"
refute "and its shelf line is gone too" grep -qF -- "→ $ID2.md" "$SHELF"

echo
echo "list and search order the pursued before the resting before the closed:"
ID3="$(W new "Notice the sky more" | tail -1)"
ID4="$(W new "A quiet hour" | tail -1)"
W dormant "$ID4" >/dev/null
LIST="$(W list)"
check "list carries the live want"      contains "$LIST" "$ID3"
check "list carries the dormant want"   contains "$LIST" "dormant"
check "the closed read as one-line outcomes" \
    contains "$LIST" "retired 20"
STATESEQ="$(W list --state all | awk '{print $1}' | uniq | tr '\n' ' ')"
check "live sorts above dormant, dormant above terminal" \
    bash -c '[[ "$1" =~ ^"live dormant "(grown-into-me\ retired|retired\ grown-into-me)\ $ ]]' _ "$STATESEQ"
check_eq "list --state live filters"    "$(W list --state live | grep -c '^live')" "2"
check "search finds by word across wants" bash -c 'DESKCRAB_WANTS_DIR="'"$WD"'" \
    python3 "'"$REPO_DIR"'/lib/eng" --kind want search whittle | grep -q learn-to-whittle'
check "search misses honestly (exit 1)" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" python3 "'"$REPO_DIR"'/lib/eng" --kind want search zanzibar-xylophone >/dev/null'

echo
echo "the kinds stay separate — no verb crosses the aisle (rule 14):"
check "settle is not a want verb" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" python3 "'"$REPO_DIR"'/lib/eng" --kind want settle x y 2>/dev/null'
check "prompt is not a want verb" \
    bash -c '! DESKCRAB_WANTS_DIR="'"$WD"'" python3 "'"$REPO_DIR"'/lib/eng" --kind want prompt 2>/dev/null'
check "grown is not an eng verb" \
    bash -c '! DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" grown x y 2>/dev/null'
check "retire is not an eng verb" \
    bash -c '! DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" retire x y 2>/dev/null'
check_eq "eng new still prints the slug alone — no shelf chatter" \
    "$(E new "Pure output" | wc -l)" "1"
check_eq "and eng records still open open" "$(E field pure-output state)" "open"

echo
echo "the crab door dispatches both kinds:"
CRAB_WANTS="$(DESKCRAB_WANTS_DIR="$WD" DESKCRAB_WANTS_FILE="$SHELF" "$REPO_DIR/crab" want list --state live)"
check "crab want list reaches the drawer" contains "$CRAB_WANTS" "$ID3"
CRAB_ENG="$(DESKCRAB_ENG_DIR="$ENG" "$REPO_DIR/crab" eng list)"
check "crab eng still answers beside it" contains "$CRAB_ENG" "the-spine-holds"

echo
echo "migration — frontmatter gained, prose byte-for-byte, dates from"
echo "evidence and never from today (rules 17-19):"
WD2="$SANDBOX/drawer2"; SHELF2="$SANDBOX/shelf2.md"
mkdir -p "$WD2"
cat > "$SHELF2" <<'SHELF'
# Wants

<!-- a comment above the list; never an entry -->

- 🎼 **Sheet music, properly** — nineteen sittings so far → sheet-music.md
- **An old flame** → old-flame.md
- **Only citations** → only-prose.md
- **A ghost** → ghost.md
SHELF
cat > "$WD2/sheet-music.md" <<'DOC'
# 🎼 Learn to read sheet music properly

Some opening prose about wanting this, with a colon: kept. The scores
themselves reach back to 2026-01-05, which is their age and not mine.

## 2026-08-21 — the first sitting

Bar one took an hour.
DOC
cat > "$WD2/old-flame.md" <<'DOC'
# An old flame

Opened 2026-08-06, when he gave me the word at 22:41 and it stuck.
We had spoken around it as early as 2026-02-02, in another context.
DOC
cat > "$WD2/only-prose.md" <<'DOC'
# Only citations

The archive holds conversations back to 2026-02-02, none of them mine.
DOC
printf 'Not a want; an artifact left beside them.\n' > "$WD2/unshelved.md"
cp "$WD2/sheet-music.md" "$SANDBOX/sheet-music.orig"
cp "$WD2/old-flame.md" "$SANDBOX/old-flame.orig"
cp "$WD2/unshelved.md" "$SANDBOX/unshelved.orig"
W2() { DESKCRAB_WANTS_DIR="$WD2" DESKCRAB_WANTS_FILE="$SHELF2" \
       python3 "$REPO_DIR/lib/eng" --kind want "$@"; }
body_of() { python3 -c 'import sys
t = open(sys.argv[1], "rb").read()
i = t.index(b"\n---\n\n")
sys.stdout.buffer.write(t[i + 6:])' "$1"; }
OUT="$(W2 migrate "$SHELF2")"
check "migrate reports its counts" contains "$OUT" "3 wants given frontmatter"
check "the missing document is named" contains "$OUT" "missing document, left as it stands: ghost.md"
check "the unshelved document is named" contains "$OUT" "not on the shelf, left untouched: unshelved.md"
check "and untouched it is" cmp -s "$WD2/unshelved.md" "$SANDBOX/unshelved.orig"
check_eq "id is the document's own stem" "$(W2 field sheet-music id)" "sheet-music"
check_eq "title is the document's own H1" \
    "$(W2 field sheet-music title)" "🎼 Learn to read sheet music properly"
check_eq "summary is the shelf line's clause, her words" \
    "$(W2 field sheet-music summary)" "nineteen sittings so far"
check_eq "state migrates live" "$(W2 field sheet-music state)" "live"
check_eq "opened is the dated heading's date — not today, not the citation" \
    "$(W2 field sheet-music opened)" "2026-08-21 00:00:00"
check_eq "an Opened phrase is evidence; running prose is a citation" \
    "$(W2 field old-flame opened)" "2026-08-06 00:00:00"
PROSE_OPENED="$(W2 field only-prose opened)"
refute "a document of citations alone never takes the cited date" \
    bash -c '[ "$1" = "2026-02-02 00:00:00" ]' _ "$PROSE_OPENED"
check "it falls to the file's own birth time instead" \
    bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]' _ "$PROSE_OPENED"
check "last_touched is a datetime" \
    bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]' _ "$(W2 field sheet-music last_touched)"
check "the body below the frontmatter is byte-for-byte the original" \
    bash -c 'python3 -c "import sys
t = open(sys.argv[1], \"rb\").read()
i = t.index(b\"\n---\n\n\")
sys.stdout.buffer.write(t[i + 6:])" "$1" | cmp -s - "$2"' _ \
    "$WD2/sheet-music.md" "$SANDBOX/sheet-music.orig"
check "for the prose one too" \
    bash -c 'python3 -c "import sys
t = open(sys.argv[1], \"rb\").read()
i = t.index(b\"\n---\n\n\")
sys.stdout.buffer.write(t[i + 6:])" "$1" | cmp -s - "$2"' _ \
    "$WD2/old-flame.md" "$SANDBOX/old-flame.orig"
cp "$WD2/sheet-music.md" "$SANDBOX/sheet-music.once"
OUT2="$(W2 migrate "$SHELF2")"
check "a second run changes nothing (idempotent)" \
    contains "$OUT2" "0 wants given frontmatter, 3 already carried it"
check "byte-for-byte nothing" cmp -s "$WD2/sheet-music.md" "$SANDBOX/sheet-music.once"
check "a migrated want answers the tool like any other" \
    bash -c 'DESKCRAB_WANTS_DIR="'"$WD2"'" DESKCRAB_WANTS_FILE="'"$SHELF2"'" \
        python3 "'"$REPO_DIR"'/lib/eng" --kind want list | grep -q sheet-music'

echo
echo "migration takes git history over every other evidence where there is any:"
WD3="$SANDBOX/drawer3"; SHELF3="$SANDBOX/shelf3.md"
mkdir -p "$WD3"
printf -- '- **Committed long ago** → committed.md\n' > "$SHELF3"
cat > "$WD3/committed.md" <<'DOC'
# Committed long ago

The document itself only names 2026-08-10.
DOC
git -C "$WD3" init -q
git -C "$WD3" add committed.md
GIT_AUTHOR_DATE="2026-08-03 12:00:00" GIT_COMMITTER_DATE="2026-08-03 12:00:00" \
    git -C "$WD3" -c user.name=t -c user.email=t@t commit -qm seed
W3() { DESKCRAB_WANTS_DIR="$WD3" DESKCRAB_WANTS_FILE="$SHELF3" \
       python3 "$REPO_DIR/lib/eng" --kind want "$@"; }
W3 migrate "$SHELF3" >/dev/null
check_eq "opened is the file's first commit date" \
    "$(W3 field committed opened)" "2026-08-03 12:00:00"
