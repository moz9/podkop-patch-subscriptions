#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
library="$test_root/installer-functions.sh"
PODKOP_PATCH_ACTION_LOCK_FILE="$test_root/action.lock"
PODKOP_PATCH_ACTION_LOCK_DIR="$test_root/action.lock.d"
PODKOP_PATCH_BACKUP_ROOT="$test_root/backups"
mkdir -p "$PODKOP_PATCH_BACKUP_ROOT"
export PODKOP_PATCH_ACTION_LOCK_FILE PODKOP_PATCH_ACTION_LOCK_DIR PODKOP_PATCH_BACKUP_ROOT

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

sed \
    -e 's/\r$//' \
    -e '/^tmp_dir="$(mktemp -d)"$/,$d' \
    "$repo_root/i" > "$library"

# shellcheck disable=SC1090
. "$library"

backup_dir=""
ensure_backup_dir
unique_backup_one="$backup_dir"
backup_dir=""
ensure_backup_dir
unique_backup_two="$backup_dir"
[ "$unique_backup_one" != "$unique_backup_two" ] &&
    [ -d "$unique_backup_one" ] && [ -d "$unique_backup_two" ] ||
    fail_test 'same-second backup allocation reused an existing directory'

failure_case="$test_root/unexpected-failure"
mkdir -p "$failure_case/backup" "$failure_case/tmp"
printf '%s\n' original > "$failure_case/backup/runtime"
printf '%s\n' partial > "$failure_case/runtime"

if (
    tmp_dir="$failure_case/tmp"
    backup_dir="$failure_case/backup"
    rollback_dir="$failure_case/backup"
    runtime_target="$failure_case/runtime"
    backup_complete=1
    restore_on_fail=1
    restore_done=0
    transaction_phase="patching"

    restore_runtime() {
        cp "$backup_dir/runtime" "$runtime_target"
        restore_done=1
    }

    trap 'installer_exit_handler "$?"' EXIT
    false
); then
    fail_test 'an unexpected installer failure returned success'
fi

[ "$(cat "$failure_case/runtime")" = original ] ||
    fail_test 'an unexpected installer failure did not restore the runtime backup'
[ ! -e "$failure_case/tmp" ] ||
    fail_test 'the installer temporary directory survived an unexpected failure'

signal_case="$test_root/signal-failure"
mkdir -p "$signal_case/backup" "$signal_case/tmp"
printf '%s\n' original > "$signal_case/backup/runtime"
printf '%s\n' partial > "$signal_case/runtime"

if SIGNAL_CASE="$signal_case" INSTALLER_LIBRARY="$library" sh -c '
    set -eu
    . "$INSTALLER_LIBRARY"
    tmp_dir="$SIGNAL_CASE/tmp"
    backup_dir="$SIGNAL_CASE/backup"
    rollback_dir="$SIGNAL_CASE/backup"
    runtime_target="$SIGNAL_CASE/runtime"
    backup_complete=1
    restore_on_fail=1
    restore_done=0
    transaction_phase="patching"
    restore_runtime() {
        cp "$backup_dir/runtime" "$runtime_target"
        restore_done=1
    }
    trap '\''installer_exit_handler "$?"'\'' EXIT
    trap '\''installer_signal_handler 143'\'' TERM
    kill -TERM "$$"
    sleep 1
'; then
    fail_test 'a TERM-interrupted installer returned success'
fi

[ "$(cat "$signal_case/runtime")" = original ] ||
    fail_test 'TERM did not restore the runtime backup'
[ ! -e "$signal_case/tmp" ] ||
    fail_test 'the installer temporary directory survived TERM'

success_case="$test_root/success"
mkdir -p "$success_case/backup" "$success_case/tmp"
printf '%s\n' original > "$success_case/backup/runtime"
printf '%s\n' installed > "$success_case/runtime"

(
    tmp_dir="$success_case/tmp"
    backup_dir="$success_case/backup"
    runtime_target="$success_case/runtime"
    backup_complete=1
    restore_on_fail=0
    restore_done=0

    restore_runtime() {
        cp "$backup_dir/runtime" "$runtime_target"
        restore_done=1
    }

    trap 'installer_exit_handler "$?"' EXIT
    true
)

[ "$(cat "$success_case/runtime")" = installed ] ||
    fail_test 'the success path unexpectedly restored the old runtime'
[ ! -e "$success_case/tmp" ] ||
    fail_test 'the installer temporary directory survived a successful exit'

retry_root="$test_root/restore-retry"
retry_rel="${retry_root#/}/blocked/runtime"
backup_dir="$retry_root/backup"
rollback_dir="$retry_root/backup"
RUNTIME_FILES="$retry_rel"
PERSISTENT_PATHS=""
backup_complete=1
restore_on_fail=1
restore_done=0
transaction_phase="patching"
rollback_generation="test-generation"
podkop_package_generation() { printf '%s\n' test-generation; }

service_root="$test_root/service-state"
mkdir -p "$service_root"
main_state_file="$service_root/main.state"
failover_state_file="$service_root/failover.state"
export main_state_file failover_state_file
cat > "$service_root/main-init" <<'SERVICE_EOF'
#!/bin/sh
case "$1" in
    running) [ "$(cat "$main_state_file")" = running ] ;;
    stop) printf '%s\n' stopped > "$main_state_file" ;;
    *) exit 1 ;;
esac
SERVICE_EOF
cat > "$service_root/main-runtime" <<'SERVICE_EOF'
#!/bin/sh
[ "$1" = restart ] || exit 1
printf '%s\n' running > "$main_state_file"
SERVICE_EOF
cat > "$service_root/failover-init" <<'SERVICE_EOF'
#!/bin/sh
case "$1" in
    running) [ "$(cat "$failover_state_file")" = running ] ;;
    restart) [ "${failover_fail_action:-}" != restart ] || exit 1; printf '%s\n' running > "$failover_state_file" ;;
    stop) [ "${failover_fail_action:-}" != stop ] || exit 1; printf '%s\n' stopped > "$failover_state_file" ;;
    *) exit 1 ;;
esac
SERVICE_EOF
chmod 755 "$service_root/main-init" "$service_root/main-runtime" "$service_root/failover-init"
PODKOP_INIT_SCRIPT="$service_root/main-init"
PODKOP_RUNTIME_BIN="$service_root/main-runtime"
DNS_FAILOVER_INIT_SCRIPT="$service_root/failover-init"
PODKOP_PATCH_RELOAD_LOG="$service_root/reload.log"

query_state="running"
query_service_running_state() { printf '%s\n' "$query_state"; }

printf '%s\n' stopped > "$main_state_file"
printf '%s\n' stopped > "$failover_state_file"
query_state="stopped"
capture_patch_service_state
printf '%s\n' running > "$main_state_file"
printf '%s\n' running > "$failover_state_file"
restore_patch_service_state || fail_test 'could not restore stopped pre-patch service state'
[ "$(cat "$main_state_file")" = running ] && [ "$(cat "$failover_state_file")" = stopped ] ||
    fail_test 'rollback did not restart main Podkop or started a stopped DNS failover service'

printf '%s\n' running > "$main_state_file"
printf '%s\n' running > "$failover_state_file"
query_state="running"
capture_patch_service_state
printf '%s\n' stopped > "$main_state_file"
printf '%s\n' stopped > "$failover_state_file"
restore_patch_service_state || fail_test 'could not restore running pre-patch service state'
[ "$(cat "$main_state_file")" = running ] && [ "$(cat "$failover_state_file")" = running ] ||
    fail_test 'rollback did not restart services that were running before patching'

DNS_FAILOVER_INIT_SCRIPT="$service_root/absent-failover-init"
capture_patch_service_state
[ "$dns_failover_service_state" = absent ] ||
    fail_test 'missing pre-patch DNS failover init was not recorded as absent'
restore_patch_service_state || fail_test 'missing pre-patch DNS failover init made rollback incomplete'

DNS_FAILOVER_INIT_SCRIPT="$service_root/failover-init"
query_state="unknown"
capture_patch_service_state
[ "$dns_failover_service_state" = unknown ] ||
    fail_test 'unreadable DNS failover state was not recorded as unknown'
printf '%s\n' stopped > "$failover_state_file"
restore_patch_service_state || fail_test 'unknown DNS failover state did not use the availability-safe restart fallback'
[ "$(cat "$failover_state_file")" = running ] ||
    fail_test 'unknown DNS failover state was treated as stopped'

query_fixture_state() {
    fixture_json="$1"
    FIXTURE_JSON="$fixture_json" INSTALLER_LIBRARY="$library" sh -c '
        . "$INSTALLER_LIBRARY"
        ubus() { printf "%s\n" "$FIXTURE_JSON"; }
        query_service_running_state podkop-dns-failover
    '
}

[ "$(query_fixture_state '{"podkop-dns-failover":{}}')" = stopped ] ||
    fail_test 'valid ubus service state without running instances was not treated as stopped'
[ "$(query_fixture_state '{"podkop-dns-failover":{"instances":{"watch":{"running":false}}}}')" = stopped ] ||
    fail_test 'valid ubus DNS failover running=false state was not treated as stopped'
[ "$(query_fixture_state '{"podkop-dns-failover":{"instances":{"watch":{"running":true}}}}')" = running ] ||
    fail_test 'valid ubus DNS failover running=true state was not treated as running'
[ "$(query_fixture_state '{"podkop-dns-failover":{"instances":"broken"}}')" = unknown ] ||
    fail_test 'malformed ubus DNS failover instances were treated as stopped'
[ "$(query_fixture_state '{"podkop-dns-failover":{"instances":{"watch":{}}}}')" = unknown ] ||
    fail_test 'ubus DNS failover instance without boolean running state was treated as stopped'
[ "$(query_fixture_state '{"podkop-dns-failover":{"instances":{"watch":{"running":"true"}}}}')" = unknown ] ||
    fail_test 'ubus DNS failover string running state was treated as stopped'

failover_fail_action=restart
export failover_fail_action
dns_failover_service_state=running
if restore_patch_service_state > "$service_root/failover-restart-failure.log" 2>&1; then
    fail_test 'DNS failover restart failure was reported as a complete service restore'
fi
failover_fail_action=""
export failover_fail_action

PODKOP_INIT_SCRIPT="/etc/init.d/podkop"
PODKOP_RUNTIME_BIN="/usr/bin/podkop"
DNS_FAILOVER_INIT_SCRIPT="/etc/init.d/podkop-dns-failover"
PODKOP_PATCH_RELOAD_LOG="/tmp/podkop-subscriptions-install-reload.log"
restart_podkop_after_restore() { return 0; }
restore_patch_service_state() { restart_podkop_after_restore; }
mkdir -p "$backup_dir/$(dirname "$retry_rel")" "$retry_root"
printf '%s\n' original > "$backup_dir/$retry_rel"
printf '%s\n' blocker > "$retry_root/blocked"

if restore_runtime > "$retry_root/first-restore.log" 2>&1; then
    fail_test 'a blocked rollback destination unexpectedly restored'
fi
[ "$restore_done" -eq 0 ] ||
    fail_test 'failed rollback was incorrectly marked complete'

rm -f "$retry_root/blocked"
mkdir -p "$retry_root/blocked"
restore_runtime > "$retry_root/second-restore.log" 2>&1 ||
    fail_test 'rollback retry did not recover after the write error cleared'
[ "$restore_done" -eq 1 ] && [ "$(cat "/$retry_rel")" = original ] ||
    fail_test 'rollback retry did not restore the original runtime file'

printf '%s\n' partial-again > "/$retry_rel"
restore_done=0
podkop_package_generation() { printf '%s\n' different-generation; }
if restore_runtime > "$retry_root/generation-mismatch.log" 2>&1; then
    fail_test 'rollback crossed a changed Podkop package generation'
fi
[ "$(cat "/$retry_rel")" = partial-again ] && [ "$restore_done" -eq 0 ] ||
    fail_test 'generation mismatch changed files or marked rollback complete'
podkop_package_generation() { printf '%s\n' test-generation; }

restart_root="$test_root/restore-restarts-podkop"
restart_rel="${restart_root#/}/runtime"
backup_dir="$restart_root/backup"
rollback_dir="$restart_root/backup"
RUNTIME_FILES="$restart_rel"
PERSISTENT_PATHS=""
backup_complete=1
restore_on_fail=1
restore_done=0
transaction_phase="patching"
rollback_generation="test-generation"
mkdir -p "$backup_dir/$(dirname "$restart_rel")" "$restart_root"
printf '%s\n' original > "$backup_dir/$restart_rel"
printf '%s\n' partial > "/$restart_rel"
restart_podkop_after_restore() {
    : > "$restart_root/restart-called"
}
restore_runtime || fail_test 'rollback with a successful Podkop restart failed'
[ -e "$restart_root/restart-called" ] ||
    fail_test 'rollback did not restart Podkop after restoring its files and config'

restore_done=0
restart_podkop_after_restore() {
    return 1
}
if restore_runtime > "$restart_root/restart-failure.log" 2>&1; then
    fail_test 'rollback reported success after the restorative Podkop restart failed'
fi
[ "$restore_done" -eq 0 ] ||
    fail_test 'rollback with a failed restorative restart was marked complete'

absent_root="$test_root/persistent-absent"
absent_rel="${absent_root#/}/created-by-update"
backup_dir="$absent_root/backup"
rollback_dir="$absent_root/backup"
PERSISTENT_PATHS="$absent_rel"
mkdir -p "$backup_dir" "/$absent_rel"
printf '%s\n' created > "/$absent_rel/value"
restore_persistent_paths || fail_test 'rollback could not restore an originally absent persistent path'
[ ! -e "/$absent_rel" ] ||
    fail_test 'rollback retained a persistent path that did not exist before the update'

incomplete_case="$test_root/incomplete-backup"
mkdir -p "$incomplete_case/backup"
backup_dir="$incomplete_case/backup"
rollback_dir="$incomplete_case/backup"
backup_complete=0
restore_on_fail=1
restore_done=0
transaction_phase="patching"
restore_marker="$incomplete_case/restore-called"
restore_runtime() {
    : > "$restore_marker"
}
restore_if_needed
[ ! -e "$restore_marker" ] ||
    fail_test 'an incomplete backup was used as a rollback source'

mkdir "$PODKOP_PATCH_ACTION_LOCK_DIR"
if installer_mutation_lock_acquire; then
    fail_test 'installer reclaimed an ownerless action-lock directory'
fi
rmdir "$PODKOP_PATCH_ACTION_LOCK_DIR"

: > "$PODKOP_PATCH_ACTION_LOCK_FILE"
if installer_mutation_lock_acquire; then
    fail_test 'installer reclaimed an ownerless legacy action lock'
fi
rm -f "$PODKOP_PATCH_ACTION_LOCK_FILE"

installer_mutation_lock_acquire ||
    fail_test 'installer could not acquire a free shared Podkop action lock'
[ -s "$PODKOP_PATCH_ACTION_LOCK_DIR/owner" ] && [ -s "$PODKOP_PATCH_ACTION_LOCK_FILE" ] ||
    fail_test 'installer did not bridge both shared Podkop action locks'
installer_mutation_lock_release
[ ! -e "$PODKOP_PATCH_ACTION_LOCK_DIR" ] && [ ! -e "$PODKOP_PATCH_ACTION_LOCK_FILE" ] ||
    fail_test 'installer did not release its shared Podkop action locks'

acquire_line="$(grep -n 'installer_mutation_lock_acquire || fail' "$repo_root/i" | cut -d: -f1)"
update_line="$(grep -n '^update_official_podkop_if_requested$' "$repo_root/i" | cut -d: -f1)"
[ -n "$acquire_line" ] && [ -n "$update_line" ] && [ "$acquire_line" -lt "$update_line" ] ||
    fail_test 'installer does not acquire the shared lock before official Podkop mutation'

if ! grep -q 'mark_latest_subscription_backend || abort_with_restore' "$repo_root/i" ||
    ! grep -q 'has_install_marker || abort_with_restore' "$repo_root/i"; then
    fail_test 'installer does not require and finally verify the release marker before commit'
fi

printf '%s\n' 'PASS: installer rollback and shared mutation lock survive unexpected failures and signals'
