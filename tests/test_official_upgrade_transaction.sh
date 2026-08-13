#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
library="$test_root/installer-functions.sh"
PODKOP_PATCH_ACTION_LOCK_FILE="$test_root/action.lock"
PODKOP_PATCH_ACTION_LOCK_DIR="$test_root/action.lock.d"
PODKOP_PATCH_BACKUP_ROOT="$test_root/backup-root"
mkdir -p "$PODKOP_PATCH_BACKUP_ROOT"
export PODKOP_PATCH_ACTION_LOCK_FILE PODKOP_PATCH_ACTION_LOCK_DIR PODKOP_PATCH_BACKUP_ROOT

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

failure_count=0

record_failure() {
    printf 'FAIL: %s\n' "$1" >&2
    failure_count=$((failure_count + 1))
}

sed \
    -e 's/\r$//' \
    -e '/^tmp_dir="$(mktemp -d)"$/,$d' \
    "$repo_root/i" > "$library"

# shellcheck disable=SC1090
. "$library"

if (
    uci() { return 1; }
    podkop_config_exists() { return 0; }
    ensure_no_pending_podkop_changes
); then
    record_failure 'pending-UCI guard accepted an unreadable UCI state'
fi
if ! (
    uci() { return 1; }
    podkop_config_exists() { return 1; }
    ensure_no_pending_podkop_changes
); then
    record_failure 'pending-UCI guard rejected the expected missing-config state on a fresh router'
fi
if (
    uci() {
        [ "$#" -eq 1 ] && [ "$1" = changes ] && printf '%s\n' 'network.lan.ipaddr=192.0.2.1'
        return 0
    }
    ensure_no_pending_uci_changes
); then
    record_failure 'global pending-UCI guard accepted an unrelated staged router change'
fi
if (
    uci() { return 1; }
    ensure_no_pending_uci_changes
); then
    record_failure 'global pending-UCI guard accepted an unreadable router UCI state'
fi

upgrade_case="$test_root/success-then-patch-failure"
mkdir -p "$upgrade_case/tmp" "$upgrade_case/backups"
printf '%s\n' runtime-0.7.20 > "$upgrade_case/tracked-runtime"
printf '%s\n' payload-0.7.20 > "$upgrade_case/untracked-payload"
printf '%s\n' 0.7.20 > "$upgrade_case/package-generation"

if (
    tmp_dir="$upgrade_case/tmp"
    backup_dir=""
    backup_complete=0
    backup_counter=0
    restore_on_fail=0
    restore_done=0
    PODKOP_PATCH_UPDATE_PODKOP=1
    PODKOP_PATCH_FORCE_PODKOP_UPDATE=1
    PODKOP_PATCH_TARGET_PODKOP_VERSION=0.7.21
    PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS="0.7.20 0.7.21"

    podkop_runtime_exists() { return 0; }
    podkop_persistent_state_exists() { return 0; }
    current_podkop_version() { cat "$upgrade_case/package-generation"; }
    installed_package_version() { cat "$upgrade_case/package-generation"; }
    uci() { return 0; }
    latest_official_podkop_version() { printf '%s\n' 0.7.21; }
    update_manager_v1_requested_podkop_upgrade() { return 1; }
    download() { printf '%s\n' '#!/bin/sh' > "$2"; }
    restore_missing_persistent_paths() { :; }

    backup_persistent_paths() {
        persistent_backup_dir="$upgrade_case/backups/pre-official-persistent"
        mkdir -p "$persistent_backup_dir"
        cp "$upgrade_case/tracked-runtime" "$persistent_backup_dir/tracked-runtime"
        printf '%s\n' "$persistent_backup_dir" > "$upgrade_case/pre-backup-dir"
    }

    backup_runtime() {
        backup_counter=$((backup_counter + 1))
        backup_dir="$upgrade_case/backups/snapshot-$backup_counter"
        rollback_dir="$backup_dir"
        mkdir -p "$backup_dir"
        cp "$upgrade_case/tracked-runtime" "$backup_dir/tracked-runtime"
        backup_complete=1
        restore_on_fail=1
        restore_done=0
        transaction_phase="patching"
    }

    restore_runtime() {
        cp "$backup_dir/tracked-runtime" "$upgrade_case/tracked-runtime"
        restore_done=1
    }

    run_official_podkop_installer() {
        printf '%s\n' runtime-0.7.21 > "$upgrade_case/tracked-runtime"
        printf '%s\n' payload-0.7.21 > "$upgrade_case/untracked-payload"
        printf '%s\n' 0.7.21 > "$upgrade_case/package-generation"
        return 0
    }

    trap 'installer_exit_handler "$?"' EXIT
    update_official_podkop_if_requested
    transaction_phase="prepatch"
    backup_runtime

    : > "$upgrade_case/reached-patch-phase"
    printf '%s\n' "$backup_dir" > "$upgrade_case/post-backup-dir"
    if [ "$(cat "$backup_dir/tracked-runtime")" = runtime-0.7.21 ]; then
        : > "$upgrade_case/post-backup-is-official"
    fi

    printf '%s\n' partial-patch-runtime > "$upgrade_case/tracked-runtime"
    false
) > "$upgrade_case/output" 2>&1; then
    record_failure 'the induced post-upgrade patch failure returned success'
fi

[ -e "$upgrade_case/reached-patch-phase" ] ||
    record_failure 'the successful official upgrade did not reach the patch phase'

pre_backup_dir="$(cat "$upgrade_case/pre-backup-dir" 2>/dev/null || true)"
post_backup_dir="$(cat "$upgrade_case/post-backup-dir" 2>/dev/null || true)"
[ -n "$pre_backup_dir" ] && [ -n "$post_backup_dir" ] &&
    [ "$pre_backup_dir" != "$post_backup_dir" ] ||
    record_failure 'pre-official and post-official rollback snapshots are not distinct'

[ -e "$upgrade_case/post-backup-is-official" ] ||
    record_failure 'the armed patch rollback snapshot still contains the pre-upgrade runtime'
[ "$(cat "$upgrade_case/tracked-runtime")" = runtime-0.7.21 ] ||
    record_failure 'late patch failure rolled the tracked runtime back across the official package boundary'
[ "$(cat "$upgrade_case/untracked-payload")" = payload-0.7.21 ] ||
    record_failure 'late patch failure changed untracked official package payload'
[ "$(cat "$upgrade_case/package-generation")" = 0.7.21 ] ||
    record_failure 'late patch failure changed official package-manager generation'

run_rejected_official_result() {
    scenario="$1"
    result="$2"
    installed_version="$3"
    podkop_package_version="${4:-$installed_version}"
    luci_package_version="${5:-$installed_version}"
    case_root="$test_root/$scenario"
    mkdir -p "$case_root/tmp"
    printf '%s\n' 0.7.20 > "$case_root/package-generation"
    persistent_rel="${case_root#/}/persistent-state"
    mkdir -p "/$persistent_rel"
    printf '%s\n' preserved > "/$persistent_rel/config"

    if (
        tmp_dir="$case_root/tmp"
        backup_dir=""
        backup_complete=0
        restore_on_fail=0
        restore_done=0
        transaction_phase="preflight"
        persistent_backup_dir=""
        rollback_dir=""
        rollback_generation=""
        PERSISTENT_PATHS="$persistent_rel"
        PODKOP_PATCH_UPDATE_PODKOP=1
        PODKOP_PATCH_FORCE_PODKOP_UPDATE=1
        PODKOP_PATCH_TARGET_PODKOP_VERSION=0.7.21
        PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS="0.7.20 0.7.21"

        podkop_runtime_exists() { return 0; }
        podkop_persistent_state_exists() { return 0; }
        current_podkop_version() { cat "$case_root/package-generation"; }
        uci() { return 0; }
        installed_package_version() {
            case "$1" in
                podkop) printf '%s\n' "$podkop_package_version" ;;
                luci-app-podkop) printf '%s\n' "$luci_package_version" ;;
                *) return 1 ;;
            esac
        }
        latest_official_podkop_version() { printf '%s\n' 0.7.21; }
        update_manager_v1_requested_podkop_upgrade() { return 1; }
        download() { printf '%s\n' '#!/bin/sh' > "$2"; }
        restore_runtime() {
            : > "$case_root/file-overlay-restore-called"
            restore_done=1
        }

        run_official_podkop_installer() {
            rm -rf "/$persistent_rel"
            printf '%s\n' "$installed_version" > "$case_root/package-generation"
            [ "$result" = success ]
        }

        update_official_podkop_if_requested
        : > "$case_root/unexpected-success"
    ) > "$case_root/output" 2>&1; then
        record_failure "$scenario official result unexpectedly proceeded to the patch phase"
    fi

    [ ! -e "$case_root/unexpected-success" ] ||
        record_failure "$scenario official result returned successfully"
    [ ! -e "$case_root/file-overlay-restore-called" ] ||
        record_failure "$scenario official result invoked an unsafe file-overlay package rollback"
    [ "$(cat "/$persistent_rel/config" 2>/dev/null || true)" = preserved ] ||
        record_failure "$scenario official result did not restore missing persistent state"
}

run_rejected_official_result official-failure failure 0.7.20
run_rejected_official_result unsupported-success success 0.8.0
run_rejected_official_result stale-success success 0.7.20
run_rejected_official_result partial-package-success success 0.7.21 0.7.21 0.7.20
run_rejected_official_result partial-revision-success success 0.7.21 v0.7.21-r2 v0.7.21-r1

official_signal_root="$test_root/official-signal"
official_signal_rel="${official_signal_root#/}/persistent-state"
mkdir -p "$official_signal_root/pre/$official_signal_rel" "$official_signal_root/tmp"
printf '%s\n' preserved > "$official_signal_root/pre/$official_signal_rel/config"
rm -rf "/$official_signal_rel"
if OFFICIAL_SIGNAL_ROOT="$official_signal_root" OFFICIAL_SIGNAL_REL="$official_signal_rel" INSTALLER_LIBRARY="$library" sh -c '
    set -eu
    . "$INSTALLER_LIBRARY"
    tmp_dir="$OFFICIAL_SIGNAL_ROOT/tmp"
    persistent_backup_dir="$OFFICIAL_SIGNAL_ROOT/pre"
    PERSISTENT_PATHS="$OFFICIAL_SIGNAL_REL"
    transaction_phase="official_update"
    restore_on_fail=0
    restore_runtime() { : > "$OFFICIAL_SIGNAL_ROOT/runtime-restore-called"; }
    trap '\''installer_exit_handler "$?"'\'' EXIT
    trap '\''installer_signal_handler 143'\'' TERM
    kill -TERM "$$"
    sleep 1
' > "$official_signal_root/output" 2>&1; then
    record_failure 'TERM during official update returned success'
fi
[ "$(cat "/$official_signal_rel/config" 2>/dev/null || true)" = preserved ] ||
    record_failure 'TERM during official update did not restore missing persistent state'
[ ! -e "$official_signal_root/runtime-restore-called" ] ||
    record_failure 'TERM during official update invoked unsafe runtime overlay rollback'
[ ! -e "$official_signal_root/tmp" ] ||
    record_failure 'TERM during official update left the installer temporary directory behind'

main_flow="$test_root/main-flow.sh"
sed -n '/^tmp_dir="$(mktemp -d)"$/,$p' "$repo_root/i" > "$main_flow"
pending_line="$(grep -n '^ensure_no_pending_podkop_changes || fail' "$main_flow" | head -n 1 | cut -d: -f1 || true)"
global_pending_line="$(grep -n '^ensure_no_pending_uci_changes || fail' "$main_flow" | head -n 1 | cut -d: -f1 || true)"
prefetch_line="$(grep -n '^prefetch_patch_assets$' "$main_flow" | cut -d: -f1 || true)"
official_line="$(grep -n '^update_official_podkop_if_requested$' "$main_flow" | cut -d: -f1 || true)"
prepatch_pending_line="$(grep -n '^ensure_no_pending_podkop_changes || fail' "$main_flow" | tail -n 1 | cut -d: -f1 || true)"
prepatch_global_pending_line="$(grep -n '^ensure_no_pending_uci_changes || fail' "$main_flow" | tail -n 1 | cut -d: -f1 || true)"
if [ -z "$global_pending_line" ] || [ -z "$pending_line" ] || [ -z "$prefetch_line" ] || [ -z "$official_line" ] || [ -z "$prepatch_global_pending_line" ] || [ -z "$prepatch_pending_line" ] ||
    [ "$global_pending_line" -ge "$pending_line" ] || [ "$pending_line" -ge "$prefetch_line" ] || [ "$prefetch_line" -ge "$official_line" ] ||
    [ "$official_line" -ge "$prepatch_global_pending_line" ] || [ "$prepatch_global_pending_line" -ge "$prepatch_pending_line" ]; then
    record_failure 'pending UCI changes and all patch downloads are not gated before the official package phase'
fi
official_function="$test_root/official-function.sh"
sed -n '/^update_official_podkop_if_requested() {/,/^}/p' "$repo_root/i" > "$official_function"
official_guard_line="$(grep -n 'ensure_no_pending_podkop_changes ||' "$official_function" | cut -d: -f1 || true)"
official_global_guard_line="$(grep -n 'ensure_no_pending_uci_changes ||' "$official_function" | cut -d: -f1 || true)"
official_run_line="$(grep -n 'run_official_podkop_installer' "$official_function" | cut -d: -f1 || true)"
if [ -z "$official_global_guard_line" ] || [ -z "$official_guard_line" ] || [ -z "$official_run_line" ] ||
    [ "$official_global_guard_line" -ge "$official_guard_line" ] || [ "$official_guard_line" -ge "$official_run_line" ]; then
    record_failure 'official package mutation is not immediately protected by a fail-closed pending-UCI guard'
fi
if [ -n "$official_line" ] && tail -n "+$((official_line + 1))" "$main_flow" | grep -q '^download '; then
    record_failure 'patch assets can still be downloaded after the official package phase commits'
fi

if [ "$failure_count" -ne 0 ]; then
    exit 1
fi

printf '%s\n' 'PASS: official Podkop upgrade and patch rollback use separate transaction generations'
