#!/bin/bash
# Existing unit deployment only, with crash/reload recovery and real caller hooks.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

SYNC="$SANDBOX_REPO/lib/unit-sync"
SRC="$SANDBOX/units"
DST="$XDG_CONFIG_HOME/systemd/user"
STATE="$XDG_STATE_HOME/deskcrab/unit-sync.json"
sandbox_stub systemctl <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SANDBOX_SYSTEMCTL_LOG"
if [ "$*" = '--user daemon-reload' ]; then
    exit "$(cat "$DESKCRAB_SANDBOX_ROOT/witness/unit-reload.rc" 2>/dev/null || echo 0)"
fi
exit 0
SH
mkdir -p "$SRC/example.service.d" "$DST/example.service.d"
printf 'new service\n' > "$SRC/example.service"
printf 'new timer\n' > "$SRC/example.timer"
printf 'new drop-in\n' > "$SRC/example.service.d/existing.conf"
printf 'new uninstalled drop-in\n' > "$SRC/example.service.d/missing.conf"
printf 'not installed\n' > "$SRC/missing.service"
printf 'old\n' | tee "$DST/example.service" "$DST/example.timer" "$DST/example.service.d/existing.conf" >/dev/null
chmod 640 "$DST/example.service"
printf 'installed only\n' > "$DST/local.service"
printf 'linked v1\n' > "$SRC/linked.service"
ln -s "$SRC/linked.service" "$DST/linked.service"
printf 'masked\n' > "$SRC/masked.service"
ln -s /dev/null "$DST/masked.service"
printf 'external source\n' > "$SRC/external.service"
printf 'external installed\n' > "$SANDBOX/external.service"
ln -s "$SANDBOX/external.service" "$DST/external.service"
run_sync() { python3 "$SYNC" --source-dir "$SRC" "$@"; }
reloads() { sandbox_count_in 'daemon-reload' "$SANDBOX_SYSTEMCTL_LOG"; }

preview="$(run_sync --check)"
check "preview names changed installed files" contains "$preview" 'example.service'
check "preview creates no evidence or installation" test ! -e "$STATE"
check_eq "preview leaves old bytes" "$(cat "$DST/example.service")" old
check_eq "preview calls no manager" "$(reloads)" 0
check "refresh succeeds" run_sync
check "existing service matches" cmp -s "$SRC/example.service" "$DST/example.service"
check "existing timer matches" cmp -s "$SRC/example.timer" "$DST/example.timer"
check "existing drop-in matches" cmp -s "$SRC/example.service.d/existing.conf" "$DST/example.service.d/existing.conf"
check_eq "installed permissions preserved" "$(stat -c %a "$DST/example.service")" 640
check "new unit is not installed" test ! -e "$DST/missing.service"
check "new drop-in is not installed" test ! -e "$DST/example.service.d/missing.conf"
check_eq "installed-only file retained" "$(cat "$DST/local.service")" 'installed only'
check_eq "one reload for the whole batch" "$(reloads)" 1
check_eq "mask preserved" "$(readlink "$DST/masked.service")" /dev/null
check_eq "external link preserved" "$(cat "$DST/external.service")" 'external installed'
check "repository link preserved" test -L "$DST/linked.service"
saved="$(cat "$STATE")"
check "no-op succeeds" run_sync
check_eq "no-op does not reload" "$(reloads)" 1
check_eq "no-op retains original refresh evidence" "$(cat "$STATE")" "$saved"
status="$(run_sync --status)"
check "status names actual refreshed files" contains "$status" example.timer
check_eq "status makes no manager calls" "$(reloads)" 1

printf 'linked v2\n' > "$SRC/linked.service"
check "repository-link edit detected despite equal source/destination" run_sync
check_eq "link edit reloads" "$(reloads)" 2
check "link still preserved" test -L "$DST/linked.service"

printf 1 > "$SANDBOX/witness/unit-reload.rc"
printf 'v2\n' > "$SRC/example.service"
run_sync
rc=$?
check_eq "failed reload is a failure" "$rc" 1
check "copy landed even though manager refused" cmp -s "$SRC/example.service" "$DST/example.service"
check_eq "pending reload is durable" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"])' "$STATE")" "['example.service']"
check "failure surfaces in status" contains "$(run_sync --status)" ATTENTION
check "failure reaches prompt state without invoking sync" \
    contains "$(sandbox_bash 'self_state_report --prompt' 2>/dev/null)" 'Unit refresh: ATTENTION'
printf 0 > "$SANDBOX/witness/unit-reload.rc"
check "next autonomous call retries equal bytes" run_sync
check_eq "failed and recovered reload each called once" "$(reloads)" 4
check "recovery clears attention" test "$(run_sync --status | grep -c ATTENTION)" = 0
check "recovery clears prompt attention" test ! -e "${STATE%.json}.attention"
check "recovered no-op succeeds" run_sync
check_eq "recovered no-op has no reload" "$(reloads)" 4

# Kill the operation after bytes land but before its reload: the pre-copy
# pending journal is what makes the next caller repair this crash window.
printf 'v3\n' > "$SRC/example.service"
python3 - "$SYNC" "$SRC" "$DST/example.service" <<'PY'
import runpy, sys
from pathlib import Path
module = runpy.run_path(sys.argv[1], run_name="unit_sync_test")
main = module['main']
original = main.__globals__['atomic_write']
target = Path(sys.argv[3])
def crash(path, *args, **kwargs):
    original(path, *args, **kwargs)
    if path == target:
        raise SystemExit(77)
main.__globals__['atomic_write'] = crash
sys.argv = [sys.argv[1], '--source-dir', sys.argv[2]]
main()
PY
check_eq "crash occurred after copy" "$?" 77
check "crash left newly copied bytes" cmp -s "$SRC/example.service" "$DST/example.service"
check "crash left pending manager work" contains "$(run_sync --status)" pending
check "next call repairs crash without another edit" run_sync
check_eq "crash recovery reloads once" "$(reloads)" 5

# A file disappearing/changing during the copy must remain a visible failure,
# never be claimed as a successful refresh or stop the next call retrying it.
printf 'v4\n' > "$SRC/example.service"
python3 - "$SYNC" "$SRC" "$DST/example.service" <<'PY'
import runpy, sys
from pathlib import Path
module = runpy.run_path(sys.argv[1], run_name="unit_sync_test")
main = module['main']
original = main.__globals__['atomic_write']
target = Path(sys.argv[3])
def fail(path, *args, **kwargs):
    if path == target:
        raise PermissionError('copy denied')
    original(path, *args, **kwargs)
main.__globals__['atomic_write'] = fail
sys.argv = [sys.argv[1], '--source-dir', sys.argv[2]]
sys.exit(main())
PY
check_eq "copy refusal is a failure" "$?" 1
check_eq "failed copy does not reload unchanged bytes" "$(reloads)" 5
check "copy refusal is visible" contains "$(run_sync --status)" 'copy denied'
check "next caller retries failed copy" run_sync
check_eq "repaired copy reloads once" "$(reloads)" 6

python3 - "$SYNC" "$SRC" <<'PY'
import fcntl, os, subprocess, sys
from pathlib import Path
lock = Path(os.environ['XDG_STATE_HOME']) / 'deskcrab/unit-sync.lock'
with lock.open('a') as fd:
    fcntl.flock(fd, fcntl.LOCK_EX)
    subprocess.run([sys.executable, sys.argv[1], '--source-dir', sys.argv[2]], check=True, timeout=2)
PY
check_eq "competing caller returns promptly" "$?" 0
check_eq "competing caller never reloads" "$(reloads)" 6
check_eq "manager calls are reloads or read-only status queries" \
    "$(grep -Evc '^--user (daemon-reload$|list-units|list-timers|show |is-active |is-enabled )' "$SANDBOX_SYSTEMCTL_LOG")" 0

printf 'stale attention\n' > "${STATE%.json}.attention"
check "no-op repairs an interrupted attention clear" run_sync
check "stale attention cleared without reload" test ! -e "${STATE%.json}.attention"
check_eq "attention repair does not reload" "$(reloads)" 6
printf '{broken journal\n' > "$STATE"
check "damaged journal is visible in read-only status" contains "$(run_sync --status)" ATTENTION
check "damaged journal recovers automatically" run_sync
check_eq "journal recovery reloads once" "$(reloads)" 7
check "damaged bytes retained for diagnosis" \
    grep -q '{broken journal' "$(find "$(dirname "$STATE")" -name 'unit-sync-damaged-*.json' -print -quit)"
check "recovered journal needs no manual clear" test "$(run_sync --status | grep -c ATTENTION)" = 0

mkdir -p "$SRC/external.service.d" "$SANDBOX/external-drops"
printf 'new drop\n' > "$SRC/external.service.d/local.conf"
printf 'local drop\n' > "$SANDBOX/external-drops/local.conf"
ln -s "$SANDBOX/external-drops" "$DST/external.service.d"
check "linked external drop-in directory is preserved" run_sync
check_eq "external drop-in bytes unchanged" "$(cat "$DST/external.service.d/local.conf")" 'local drop'
check_eq "external drop-in does not reload" "$(reloads)" 7

# A durability error after rename still owes the manager the new definition.
printf 'v5\n' > "$SRC/example.service"
python3 - "$SYNC" "$SRC" "$DST/example.service" <<'PY'
import runpy, sys
from pathlib import Path
module = runpy.run_path(sys.argv[1], run_name="unit_sync_test")
main = module['main']
original = main.__globals__['atomic_write']
target = Path(sys.argv[3])
def post_replace_error(path, *args, **kwargs):
    original(path, *args, **kwargs)
    if path == target:
        raise OSError('directory fsync failed after rename')
main.__globals__['atomic_write'] = post_replace_error
sys.argv = [sys.argv[1], '--source-dir', sys.argv[2]]
sys.exit(main())
PY
check_eq "post-replace error remains visible" "$?" 1
check "post-replace error did land the new bytes" cmp -s "$SRC/example.service" "$DST/example.service"
check_eq "post-replace error still reloads changed definition" "$(reloads)" 8
check "post-replace error clears on automatic reconciliation" run_sync
check_eq "reconciliation avoids a redundant reload" "$(reloads)" 8

# Use the actual watcher in a tiny repository so first-run and no-change
# exits prove deployment precedes snapshot/attribution filtering.
FIXTURE="$SANDBOX/watcher-repo"
mkdir -p "$FIXTURE/lib" "$FIXTURE/systemd"
cp "$SYNC" "$SANDBOX_REPO/lib/notice-selfchange" "$FIXTURE/lib/"
chmod +x "$FIXTURE/lib/unit-sync"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/crab"
chmod +x "$FIXTURE/crab"
git -C "$FIXTURE" init -q -b test
printf 'watch v1\n' > "$FIXTURE/systemd/watch.service"
printf 'old\n' > "$DST/watch.service"
"$FIXTURE/lib/notice-selfchange" 99
check "watcher seed exit deploys unit" cmp -s "$FIXTURE/systemd/watch.service" "$DST/watch.service"
printf 'watch v2\n' > "$FIXTURE/systemd/watch.service"
"$FIXTURE/lib/notice-selfchange" 99
check "watcher no-change exit deploys untracked/ignored snapshot unit" cmp -s "$FIXTURE/systemd/watch.service" "$DST/watch.service"

# The watcher normally exits early here; an edit made during snapshot must
# still be picked up by its exit reconciliation.
sandbox_stub find <<'SH'
#!/bin/bash
if [ ! -e "$DESKCRAB_SANDBOX_ROOT/snapshot-edited" ]; then
    printf 'watch v3\n' > "$DESKCRAB_SANDBOX_ROOT/watcher-repo/systemd/watch.service"
    touch "$DESKCRAB_SANDBOX_ROOT/snapshot-edited"
fi
exec /usr/bin/find "$@"
SH
"$FIXTURE/lib/notice-selfchange" 99
check "watcher exit catches an edit made while watcher runs" cmp -s "$FIXTURE/systemd/watch.service" "$DST/watch.service"

cp "$SANDBOX_REPO/lib/canary-selfchange" "$FIXTURE/lib/"
sandbox_stub systemctl <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SANDBOX_SYSTEMCTL_LOG"
case "$*" in
    *is-active*) echo active ;;
    *is-enabled*) echo enabled ;;
esac
exit 0
SH
printf 'watch v4\n' > "$FIXTURE/systemd/watch.service"
CANARY_TIMEOUT=0 "$FIXTURE/lib/canary-selfchange" --no-wake --quiet
check "canary deploys independently while watcher busy" cmp -s "$FIXTURE/systemd/watch.service" "$DST/watch.service"
check_eq "integration never starts, restarts, enables or stops units" \
    "$(grep -Ec -- '--user (start|stop|restart|enable|disable)( |$)' "$SANDBOX_SYSTEMCTL_LOG")" 0
