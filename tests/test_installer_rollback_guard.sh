#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
library="$test_root/installer-functions.sh"
PODKOP_PATCH_ACTION_LOCK_FILE="$test_root/action.lock"
PODKOP_PATCH_ACTION_LOCK_DIR="$test_root/action.lock.d"
export PODKOP_PATCH_ACTION_LOCK_FILE PODKOP_PATCH_ACTION_LOCK_DIR

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

failure_case="$test_root/unexpected-failure"
mkdir -p "$failure_case/backup" "$failure_case/tmp"
printf '%s\n' original > "$failure_case/backup/runtime"
printf '%s\n' partial > "$failure_case/runtime"

if (
    tmp_dir="$failure_case/tmp"
    backup_dir="$failure_case/backup"
    runtime_target="$failure_case/runtime"
    backup_complete=1
    restore_on_fail=1
    restore_done=0

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
    runtime_target="$SIGNAL_CASE/runtime"
    backup_complete=1
    restore_on_fail=1
    restore_done=0
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
RUNTIME_FILES="$retry_rel"
PERSISTENT_PATHS=""
backup_complete=1
restore_on_fail=1
restore_done=0
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

absent_root="$test_root/persistent-absent"
absent_rel="${absent_root#/}/created-by-update"
backup_dir="$absent_root/backup"
PERSISTENT_PATHS="$absent_rel"
mkdir -p "$backup_dir" "/$absent_rel"
printf '%s\n' created > "/$absent_rel/value"
restore_persistent_paths || fail_test 'rollback could not restore an originally absent persistent path'
[ ! -e "/$absent_rel" ] ||
    fail_test 'rollback retained a persistent path that did not exist before the update'

incomplete_case="$test_root/incomplete-backup"
mkdir -p "$incomplete_case/backup"
backup_dir="$incomplete_case/backup"
backup_complete=0
restore_on_fail=1
restore_done=0
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

sed -n '/if version_ge "$current_version" "$target_version"; then/,/return 0/p' "$repo_root/i" |
    grep -q 'restore_done=0' ||
    fail_test 'installer does not re-arm rollback after recovering from an official update failure'

printf '%s\n' 'PASS: installer rollback and shared mutation lock survive unexpected failures and signals'
