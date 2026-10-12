#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
runner=''; child=''
cleanup() { [ -z "$runner" ] || kill "$runner" 2>/dev/null || true; [ -z "$child" ] || kill "$child" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$work/fake-downloader" <<'CHILD'
#!/bin/sh
printf '%s\n' "$$" > "$CHILD_PID_FILE"
printf 'partial body\n' > "$BODY_FILE"
exec sleep 60
CHILD
chmod +x "$work/fake-downloader"
cat > "$work/runner" <<'RUNNER'
#!/bin/sh
. "$1/openwrt/podkop-subscription-sources.sh"
work="$2"
subscription_resource_limits || exit 1
trap 'echo cleaned > "$work/exit-cleaned"' EXIT
trap 'echo original > "$work/term-restored"' TERM
export CHILD_PID_FILE="$work/child-pid" BODY_FILE="$work/body"
if [ "${PODKOP_TEST_SIGNAL_DURING_LAUNCH:-0}" = 1 ]; then
    eval "$(sed -n '/^subscription_download_pid_start() {$/,/^}$/p' "$1/openwrt/podkop-subscription-sources.sh" | sed '1s/subscription_download_pid_start()/original_pid_start()/')"
    subscription_download_pid_start() {
        # $$ remains the runner identity inside this command substitution.
        kill -TERM "$$"
        original_pid_start "$1"
    }
fi
subscription_download_guarded "$work/body" "$work/headers" "$work/fake-downloader"
status=$?
# Normal return must restore the callers original TERM trap.
trap > "$work/restored-traps"
grep -Fq term-restored "$work/restored-traps" || exit 99
exit "$status"
RUNNER
start_runner() {
    rm -f "$work/child-pid" "$work/exit-cleaned"
    sh "$work/runner" "$repo" "$work" & runner=$!
    count=0
    while [ ! -s "$work/child-pid" ]; do
        count=$((count + 1)); [ "$count" -lt 100 ] || fail 'child did not start'; sleep 0.05
    done
    child="$(cat "$work/child-pid")"
}
start_runner
kill -TERM "$runner"
status=0; wait "$runner" || status=$?; runner=''
[ "$status" -eq 143 ] || fail 'cancellation did not stop refresh worker'
if kill -0 "$child" 2>/dev/null; then fail 'cancellation orphaned downloader'; fi
child=''
[ -s "$work/exit-cleaned" ] || fail 'cancellation skipped original EXIT cleanup'
[ ! -e "$work/body" ] || fail 'cancellation retained partial body'
PODKOP_SUBSCRIPTION_DOWNLOAD_TIMEOUT_SECONDS=1
export PODKOP_SUBSCRIPTION_DOWNLOAD_TIMEOUT_SECONDS
start_runner
status=0; wait "$runner" || status=$?; runner=''
[ "$status" -eq 124 ] || fail 'wall-clock deadline was not enforced/restored traps'
if kill -0 "$child" 2>/dev/null; then fail 'timeout orphaned downloader'; fi
child=''
[ -s "$work/exit-cleaned" ] || fail 'timeout skipped original EXIT cleanup'
unset PODKOP_SUBSCRIPTION_DOWNLOAD_TIMEOUT_SECONDS
PODKOP_TEST_SIGNAL_DURING_LAUNCH=1
export PODKOP_TEST_SIGNAL_DURING_LAUNCH
rm -f "$work/child-pid" "$work/exit-cleaned"
sh "$work/runner" "$repo" "$work" & runner=$!
status=0; wait "$runner" || status=$?; runner=''
[ "$status" -eq 143 ] || fail 'launch-window signal was not deferred then honored'
if [ -s "$work/child-pid" ]; then
    child="$(cat "$work/child-pid")"
    if kill -0 "$child" 2>/dev/null; then fail 'launch-window signal orphaned downloader'; fi
    child=''
fi
[ -s "$work/exit-cleaned" ] || fail 'launch-window cancellation skipped caller cleanup'
unset PODKOP_TEST_SIGNAL_DURING_LAUNCH
# Kernel cap runs in the real executable child and cannot leak to parent shell.
. "$repo/openwrt/podkop-subscription-sources.sh"
subscription_resource_limits
limit_before="$(ulimit -f)"
status=0
subscription_download_guarded "$work/large" "$work/headers" dd if=/dev/zero of="$work/large" bs=3145728 count=1 2>/dev/null || status=$?
[ "$status" -ne 0 ] || fail 'real child file-size cap did not stop writer'
[ "$(wc -c < "$work/large")" -le 2097152 ] || fail 'real child exceeded conservative cap'
[ "$(ulimit -f)" = "$limit_before" ] || fail 'file limit leaked to parent'
# A correct starttime with the wrong parent is not an owned child.
sleep 60 & child=$!
identity="$(subscription_download_pid_start "$child")"
subscription_download_kill_child "$child" "$identity" 999999999
kill -0 "$child" 2>/dev/null || fail 'wrong-parent identity received a signal'
kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; child=''
# Never signal a reused PID; recheck identity separately before escalation.
(
    kill() { echo "$*" >> "$work/signals"; }
    subscription_download_pid_start() { echo new; }
    subscription_download_kill_child 123 old
    [ ! -e "$work/signals" ] || fail 'stale identity received a signal'
    subscription_download_pid_start() {
        if [ -e "$work/signals" ]; then echo new; else echo old; fi
    }
    subscription_download_kill_child 123 old
    [ "$(cat "$work/signals")" = '-TERM 123' ] || fail 'identity was not rechecked before KILL'
)
echo 'PASS: real downloader child killed/reaped on cancel and timeout; original traps restored and file limit isolated'
