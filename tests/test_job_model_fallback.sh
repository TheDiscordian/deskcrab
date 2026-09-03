#!/bin/bash
# Tests for the per-job model override, the ordered fallback family walk, and
# the family-scoped block marker — specs/jobs.md rules 5b, 5c, 16 and 17, from
# the engineering record every-builder-job-is-pinned-to-fable-so-one-mode.
#
# The night these were written for (2026-08-28): JOB_MODEL="fable" pinned
# every detached builder to one family, all three accounts hit that family's
# limit, and nine dispatches across seven hours each died in four seconds —
# while the same accounts were answering other families the whole time. Three
# family-blind guesses stacked: the flat block marker held EVERY dispatch
# whatever its model, and the armed retry fired into the provably dry family.
#
# One deliberate deviation from the record's own wording, dated here: the
# record asked for a preflight against account-state's per-(model, account)
# cooldowns and a retry timer computed from the recorded expiry. Commit
# 9eeb40c (2026-09-03) removed ALL cooldown bookkeeping from the account walk
# on purpose (account-fallback.md rule 8: guessed resets benched accounts
# that answered on the first probe), so there is no recorded expiry left to
# consult and none may be reintroduced. What stands instead: the block
# marker — the one hold the jobs path still records — is scoped to the
# families that actually refused, and the single retry probe is armed from
# that marker's own expiry window (JOB_BLOCK_RETRY + margin), once, never a
# loop. Those are the shapes pinned below.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
LIVE="$XDG_DATA_HOME/deskcrab/jobs"
mkdir -p "$LIVE" "$T/wd" "$T/journal" "$T/metrics"
printf -- '- a want\n' > "$T/wants.md"

# The conf under test is the sandbox's own scratch copy — never the user's.
# It pins JOB_MODEL=fable exactly as the live conf does, and its bytes are
# photographed so rule 5c's "the conf is untouched" is an assertion, not a
# promise.
printf 'JOB_MODEL="fable"\n' >> "$DESKCRAB_CONF"
CONF_SHA="$(sha256sum "$DESKCRAB_CONF" | cut -d' ' -f1)"

# systemd-run records and ACCEPTS, so the dispatch doors believe their unit
# started, write their stamps, and never fall back to setsid-ing a real
# worker (the same swap test_job_block_retry.sh makes for its stamp stanza).
sandbox_stub systemd-run <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SANDBOX_SYSTEMD_LOG:-/dev/null}"
exit 0
EOF

sb() { sandbox_bash "$@"; }
getf() { "$REPO_DIR/lib/job-status" get "$1" "$2"; } # <sidecar> <field>
newest_json() { ls -t "$1"/*.json 2>/dev/null | head -n1; }

# ---------------------------------------------------------------------------
echo "the door — a per-job --model beats JOB_MODEL, conf untouched (rule 5c):"
out="$(sb 'job_start --model opus "repaint the letterbox in opus"' 2>&1)"
id="$(printf '%s\n' "$out" | sed -n 's/^Job \([0-9-]*-[0-9]*\) dispatched.*/\1/p')"
if [ -n "$id" ] && [ -e "$SANDBOX/data/deskcrab/jobs/$id.json" ]; then
    ok "the override dispatches (job $id)"
    check_eq "the request is on the sidecar" \
        "$(getf "$SANDBOX/data/deskcrab/jobs/$id.json" model_request)" "opus"
    check_eq "and the model stamp is the override, not the conf's fable" \
        "$(getf "$SANDBOX/data/deskcrab/jobs/$id.json" model)" "opus"
else
    fail "an override dispatch must create a sidecar" "$out"
fi

out="$(sb 'job_start "sand the letterbox as the conf says"' 2>&1)"
id2="$(printf '%s\n' "$out" | sed -n 's/^Job \([0-9-]*-[0-9]*\) dispatched.*/\1/p')"
if [ -n "$id2" ] && [ -e "$SANDBOX/data/deskcrab/jobs/$id2.json" ]; then
    check_eq "no flag: the default family stays the conf's own" \
        "$(getf "$SANDBOX/data/deskcrab/jobs/$id2.json" model)" "fable"
    check_eq "and no request is invented" \
        "$(getf "$SANDBOX/data/deskcrab/jobs/$id2.json" model_request)" ""
else
    fail "a plain dispatch must still work" "$out"
fi

out="$(sb 'job_start --model "bad name!" "never this"' 2>&1)"
case "$out" in
    *"not a model name"*) ok "a malformed model name is refused in plain words" ;;
    *) fail "bad --model must be refused" "$out" ;;
esac
check_eq "…creating nothing" \
    "$(sandbox_count_in "never this" "$(newest_json "$SANDBOX/data/deskcrab/jobs")")" "0"

check_eq "the conf's bytes never moved for any of it" \
    "$(sha256sum "$DESKCRAB_CONF" | cut -d' ' -f1)" "$CONF_SHA"

# ---------------------------------------------------------------------------
echo
echo "the marker — a fable block holds fable, not the other families (rule 16):"
sb 'job_block_record "You'\''ve reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model" fable' >/dev/null 2>&1
out="$(sb 'job_start "varnish the shutters at the pinned family"' 2>&1)"
case "$out" in
    *"the last job never began"*) ok "a fable dispatch is held by the fable marker" ;;
    *) fail "the refused family must stay held" "$out" ;;
esac
out="$(sb 'job_start --model opus "varnish the shutters on opus instead"' 2>&1)"
case "$out" in
    *dispatched*) ok "an opus dispatch passes the fable marker — the hold is family-scoped" ;;
    *) fail "another family must not be held by fable's refusal" "$out" ;;
esac

# The pre-scope marker shape — <epoch> TAB <reason> — reads as family-blind,
# so an old marker on disk keeps exactly the behaviour it was written with.
sb 'printf "%s\tout of usage credits\n" "$(date +%s)" > "$JOBS_BLOCKED_FILE"' >/dev/null 2>&1
out="$(sb 'job_start --model opus "legacy marker, opus try"' 2>&1)"
case "$out" in
    *"the last job never began"*) ok "a legacy two-field marker still holds every family" ;;
    *) fail "legacy markers must stay family-blind" "$out" ;;
esac
out="$(sb 'job_start "legacy marker, fable try"' 2>&1)"
case "$out" in
    *"the last job never began"*) ok "…fable included" ;;
    *) fail "legacy markers must hold the pinned family too" "$out" ;;
esac

echo
echo "the queued door judges the record's own request the same way (rule 16):"
sb 'job_block_record "reached your Fable 5 limit" fable' >/dev/null 2>&1
"$REPO_DIR/lib/job-status" new "$SANDBOX/data/deskcrab/jobs" qov "an opus-pinned queued brief" "" "$T/wd" queued
"$REPO_DIR/lib/job-status" set "$SANDBOX/data/deskcrab/jobs/qov.json" model_request=opus
out="$(sb 'job_dispatch_queued qov' 2>&1)"
case "$out" in
    *dispatched*) ok "a queued opus brief passes the fable marker" ;;
    *) fail "the queued door must judge the record's own family" "$out" ;;
esac
"$REPO_DIR/lib/job-status" new "$SANDBOX/data/deskcrab/jobs" qpl "a plain queued brief" "" "$T/wd" queued
out="$(sb 'job_dispatch_queued qpl' 2>&1)"
case "$out" in
    *"the last job never began"*) ok "a plain queued brief is still fable, still held" ;;
    *) fail "the queued door must hold the refused family" "$out" ;;
esac
sb 'rm -f "$JOBS_BLOCKED_FILE"' >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "the worker — the ordered family walk (rule 5b):"
# The runner is copied so SCRIPT_DIR/crab is a stub; common.sh is a symlink,
# so LIB_DIR walks back to the real repo tools — the shape every job suite
# uses. The claude stub refuses BY MODEL: fable always (the 2026-08-11
# model-limit wording, which the shared signature matches), everything on
# STUB_REFUSE_ALL, and answers otherwise. Every call is on the record.
mkdir -p "$T/repo/lib"
cp "$REPO_DIR/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh"
chmod +x "$T/repo/lib/job-runner"
printf '#!/bin/bash\nexit 0\n' > "$T/repo/crab"; chmod +x "$T/repo/crab"
cat > "$T/claude-bymodel" <<EOF
#!/bin/bash
model=""; prev=""
for a in "\$@"; do [ "\$prev" = "--model" ] && model="\$a"; prev="\$a"; done
echo "CALL model=\$model acct=\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ "\$model" = "fable" ] || [ -n "\${STUB_REFUSE_ALL:-}" ]; then
    echo "You've reached your \$model limit. Run /usage-credits to continue or switch models with /model"
    exit 1
fi
echo "BUILT OK on \$model"
EOF
chmod +x "$T/claude-bymodel"

run_runner() { # <id> [ENV=val ...]
    local id="$1"; shift
    [ -e "$LIVE/$id.json" ] || \
        "$REPO_DIR/lib/job-status" new "$LIVE" "$id" "family walk case $id" "" "$T/wd" >/dev/null 2>&1
    JOBS_DIR="$LIVE" WANTS_FILE="$T/wants.md" CLAUDE_BIN="$T/claude-bymodel" \
        JOBS_BLOCKED_FILE="$T/marker" DAY_JOURNAL_DIR="$T/journal" \
        DESKCRAB_METRICS_DIR="$T/metrics" ACCOUNT_STATE_FILE="$T/account-state" \
        env "$@" "$T/repo/lib/job-runner" "$id" "$T/wd" >/dev/null 2>&1
}

rm -f "$T/calls" "$T/marker" "$T/account-state"
run_runner walk1
check_eq "fable dry, opus answers: the job finishes" \
    "$(getf "$LIVE/walk1.json" state)" "collected"
check_eq "two calls: the refused family, then the next in the list" \
    "$(sandbox_count_in "CALL" "$T/calls")" "2"
check_eq "the first ran the pinned fable" \
    "$(sed -n '1p' "$T/calls" | grep -c "model=fable")" "1"
check_eq "the second ran opus — the walk's next family" \
    "$(sed -n '2p' "$T/calls" | grep -c "model=opus")" "1"
check_eq "the sidecar names the family the build ACTUALLY used" \
    "$(getf "$LIVE/walk1.json" model)" "opus"
check "the walk is loud in the job's own log" \
    grep -q "every account refused at fable — walking to opus" "$LIVE/walk1.log"
check "…and on the attempts record" \
    grep -q "family walk" <(getf "$LIVE/walk1.json" attempts)

# Two accounts, a legacy fable cooldown row on the books for account 1: the
# row is a ledger nothing writes any more (account-fallback.md rule 8) and
# blocks nothing — the very account it names takes the opus build the moment
# fable's walk is done. This is the record's own 06:52 proof, mechanised.
rm -f "$T/calls" "$T/marker"
mkdir -p "$T/two"
printf 'cooldown\t1\t%s\t%s\tsession\tfable\n' "$HOME/.claude" "$(( $(date +%s) + 7200 ))" > "$T/account-state"
run_runner walk2 CLAUDE_FALLBACK_CONFIG_DIR="$T/two"
check_eq "the walk finishes past a recorded fable cooldown" \
    "$(getf "$LIVE/walk2.json" state)" "collected"
check_eq "three calls: fable on both accounts, then opus" \
    "$(sandbox_count_in "CALL" "$T/calls")" "3"
check_eq "the opus build ran on an account the ledger called cooling" \
    "$(sed -n '3p' "$T/calls" | grep -c "model=opus")" "1"

echo
echo "the worker — the list is the user's order, and the override leads it:"
rm -f "$T/calls" "$T/marker" "$T/account-state"
run_runner walk3 JOB_MODEL_FALLBACK="sonnet"
check_eq "a configured fallback list is followed, not the default" \
    "$(sed -n '2p' "$T/calls" | grep -c "model=sonnet")" "1"
check_eq "…and opus, not in the list, is never tried" \
    "$(sandbox_count_in "model=opus" "$T/calls")" "0"
check_eq "the sidecar records sonnet as the family used" \
    "$(getf "$LIVE/walk3.json" model)" "sonnet"

rm -f "$T/calls" "$T/marker" "$T/account-state"
"$REPO_DIR/lib/job-status" new "$LIVE" walk4 "family walk case walk4" "" "$T/wd" >/dev/null 2>&1
"$REPO_DIR/lib/job-status" set "$LIVE/walk4.json" model_request=opus
run_runner walk4
check_eq "the sidecar's request outranks the conf's fable in the worker too" \
    "$(sed -n '1p' "$T/calls" | grep -c "model=opus")" "1"
check_eq "one call — the override answered, no fable attempt anywhere" \
    "$(sandbox_count_in "CALL" "$T/calls")" "1"

# ---------------------------------------------------------------------------
echo
echo "the worker — every family dry: blocked, with the families on the marker:"
rm -f "$T/calls" "$T/marker" "$T/account-state"
: > "$SANDBOX_SYSTEMD_LOG"
run_runner dry1 STUB_REFUSE_ALL=1
check_eq "nothing answered: the job is blocked, as before" \
    "$(getf "$LIVE/dry1.json" state)" "blocked"
check_eq "three calls: fable, opus, sonnet — the whole default list" \
    "$(sandbox_count_in "CALL" "$T/calls")" "3"
mk_fams="$(awk -F'\t' '{print $2; exit}' "$T/marker" 2>/dev/null)"
check_eq "the marker names every family the walk was refused at" \
    "$mk_fams" "fable,opus,sonnet"

echo
echo "the retry probe — armed once, from the marker's own window (rules 17, 18a):"
argv="$(grep -m1 'deskcrab-job-retry-dry1' "$SANDBOX_SYSTEMD_LOG" 2>/dev/null)"
case "$argv" in
    *"--on-active=1860s"*) ok "the probe is the window's expiry plus the margin (1800+60)" ;;
    *) fail "the retry must be armed past the marker's own expiry" "$argv" ;;
esac
check_eq "and exactly one is armed — a probe, never a loop" \
    "$(sandbox_count_in "deskcrab-job-retry-dry1" "$SANDBOX_SYSTEMD_LOG")" "1"

rm -f "$T/calls" "$T/marker"
: > "$SANDBOX_SYSTEMD_LOG"
run_runner dry2 STUB_REFUSE_ALL=1 JOB_BLOCK_RETRY=900
argv="$(grep -m1 'deskcrab-job-retry-dry2' "$SANDBOX_SYSTEMD_LOG" 2>/dev/null)"
case "$argv" in
    *"--on-active=960s"*) ok "the probe follows the window it is derived from (900+60)" ;;
    *) fail "the retry must be computed from the hold, not a constant" "$argv" ;;
esac

rm -f "$T/calls" "$T/marker"
: > "$SANDBOX_SYSTEMD_LOG"
"$REPO_DIR/lib/job-status" new "$LIVE" dry3 "family walk case dry3" "" "$T/wd" >/dev/null 2>&1
"$REPO_DIR/lib/job-status" set "$LIVE/dry3.json" retry_of=dry1
run_runner dry3 STUB_REFUSE_ALL=1
check_eq "a retry that blocks arms nothing — the chain ends, no tight loop" \
    "$(sandbox_count_in "deskcrab-job-retry-dry3" "$SANDBOX_SYSTEMD_LOG")" "0"

echo
echo "the marker the dry walk wrote scopes the door (rule 16):"
out="$(sb 'JOBS_BLOCKED_FILE="'"$T"'/marker" job_start --model sonnet "a sonnet brief into the dry spell"' 2>&1)"
case "$out" in
    *"the last job never began"*) ok "a family the walk proved dry is held" ;;
    *) fail "sonnet was on the refused list and must be held" "$out" ;;
esac
out="$(sb 'JOBS_BLOCKED_FILE="'"$T"'/marker" job_start --model haiku "a haiku brief past the dry spell"' 2>&1)"
case "$out" in
    *dispatched*) ok "a family the walk never saw refused passes" ;;
    *) fail "haiku was not refused and must pass the marker" "$out" ;;
esac

# ---------------------------------------------------------------------------
echo
echo "the chain — requeue and the automatic retry carry the request (rule 5c):"
"$REPO_DIR/lib/job-status" new "$LIVE" chain1 "rebuild the weathervane" "" "$T/wd" >/dev/null 2>&1
"$REPO_DIR/lib/job-status" set "$LIVE/chain1.json" state=blocked exit=1 model_request=opus
: > "$LIVE/chain1.log"
env JOBS_DIR="$LIVE" DESKCRAB_NO_DISPATCH=1 JOBS_BLOCKED_FILE="$T/no-marker" \
    "$REPO_DIR/lib/job-block-retry" chain1 >/dev/null 2>&1
check "the fired retry names the recorded model" \
    grep -q "Would dispatch.*rebuild the weathervane.*(model: opus)" "$LIVE/chain1.log"

"$REPO_DIR/lib/job-status" new "$LIVE" chain2 "regild the weathercock" "" "$T/wd" >/dev/null 2>&1
"$REPO_DIR/lib/job-status" set "$LIVE/chain2.json" state=failed exit=1 model_request=opus
out="$(sb 'JOBS_DIR="'"$LIVE"'" DESKCRAB_NO_DISPATCH=1 job_requeue chain2' 2>&1)"
case "$out" in
    *"(model: opus)"*) ok "requeue reads the request off the sidecar" ;;
    *) fail "a requeued brief must keep its model" "$out" ;;
esac

# ---------------------------------------------------------------------------
echo
check_eq "after everything, the conf's bytes still never moved (rule 5c)" \
    "$(sha256sum "$DESKCRAB_CONF" | cut -d' ' -f1)" "$CONF_SHA"
