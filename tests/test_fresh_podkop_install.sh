#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
library="$test_root/installer-functions.sh"
official_fixture="$test_root/official-installer.sh"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

unset PODKOP_PATCH_UPDATE_PODKOP PODKOP_PATCH_FORCE_PODKOP_UPDATE
sed \
    -e 's/\r$//' \
    -e '/^tmp_dir="$(mktemp -d)"$/,$d' \
    "$repo_root/i" > "$library"

# shellcheck disable=SC1090
. "$library"

[ "$PODKOP_PATCH_UPDATE_PODKOP" = 1 ] ||
    fail_test 'the unified installer does not enable official Podkop installation by default'
[ "$PODKOP_PATCH_UPDATE_PODKOP_WAS_SET" = 0 ] ||
    fail_test 'the implicit default was incorrectly treated as an explicit update request'

cat > "$official_fixture" <<'OFFICIAL_FIXTURE_EOF'
#!/bin/sh
set -eu

first_answer=""
second_answer=""
IFS= read -r first_answer || true
IFS= read -r second_answer || true
printf '%s\n%s\n' "$first_answer" "$second_answer" > "$FRESH_ANSWERS"
: > "$FRESH_INVOKED"

mkdir -p "$FRESH_CONFIG_DIR" "$FRESH_STATE_DIR"
printf '%s\n' official-default > "$FRESH_CONFIG_DIR/podkop"
printf '%s\n' official-state > "$FRESH_STATE_DIR/installed"

{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ "${1:-}" = show_version ]; then'
    printf '    printf '\''%%s\\n'\'' '\''%s'\''\n' "$FRESH_VERSION"
    printf '%s\n' 'fi'
} > "$FRESH_BIN"
chmod 755 "$FRESH_BIN"

[ "$FRESH_RESULT" != failure ] || exit 1
OFFICIAL_FIXTURE_EOF
chmod 755 "$official_fixture"

run_case() {
    scenario="$1"
    version="$2"
    expected_status="$3"
    case_root="$test_root/$scenario"
    mkdir -p "$case_root/tmp"

    if (
        tmp_dir="$case_root/tmp"
        backup_dir=""
        persistent_backup_dir=""
        rollback_dir=""
        rollback_generation=""
        backup_complete=0
        restore_on_fail=0
        restore_done=0
        transaction_phase="preflight"
        fixture_bin="$case_root/podkop"
        FRESH_BIN="$fixture_bin"
        FRESH_VERSION="$version"
        FRESH_RESULT="$scenario"
        FRESH_ANSWERS="$case_root/answers"
        FRESH_INVOKED="$case_root/invoked"
        FRESH_CONFIG_DIR="$case_root/etc-config"
        FRESH_STATE_DIR="$case_root/etc-podkop"
        export FRESH_BIN FRESH_VERSION FRESH_RESULT FRESH_ANSWERS FRESH_INVOKED
        export FRESH_CONFIG_DIR FRESH_STATE_DIR

        podkop_runtime_exists() {
            [ -x "$fixture_bin" ]
        }

        podkop_persistent_state_exists() {
            return 1
        }

        current_podkop_version() {
            "$fixture_bin" show_version 2>/dev/null | sed 's/^v//' || true
        }

        installed_package_version() {
            printf '%s\n' "$FRESH_VERSION"
        }

        uci() {
            return 0
        }

        latest_official_podkop_version() {
            printf '%s\n' 0.7.22
        }

        update_manager_v1_requested_podkop_upgrade() {
            return 1
        }

        download() {
            [ "$1" = "$PODKOP_OFFICIAL_INSTALL_URL" ] ||
                fail "unexpected official installer URL: $1"
            printf '%s\n' "$1" > "$case_root/download-url"
            cp "$official_fixture" "$2"
        }

        backup_runtime() {
            : > "$case_root/backup-called"
        }

        restore_runtime() {
            : > "$case_root/restore-called"
            restore_done=1
        }

        update_official_podkop_if_requested
        : > "$case_root/patch-phase"
    ) > "$case_root/output" 2>&1; then
        actual_status=0
    else
        actual_status=$?
    fi

    if [ "$expected_status" = success ]; then
        [ "$actual_status" -eq 0 ] ||
            fail_test "$scenario fresh installation failed unexpectedly"
    else
        [ "$actual_status" -ne 0 ] ||
            fail_test "$scenario fresh installation unexpectedly succeeded"
    fi

    [ -e "$case_root/invoked" ] ||
        fail_test "$scenario did not invoke the official Podkop installer"
    [ "$(sed -n '1p' "$case_root/answers")" = yes ] &&
        [ "$(sed -n '2p' "$case_root/answers")" = n ] ||
        fail_test "$scenario did not provide deterministic non-interactive answers"
    [ "$(cat "$case_root/download-url")" = "$PODKOP_OFFICIAL_INSTALL_URL" ] ||
        fail_test "$scenario did not download the configured official installer"
    [ -f "$case_root/etc-config/podkop" ] &&
        [ -f "$case_root/etc-podkop/installed" ] ||
        fail_test "$scenario deleted state created by the official fresh installer"
    [ ! -e "$case_root/backup-called" ] && [ ! -e "$case_root/restore-called" ] ||
        fail_test "$scenario pretended a file backup could roll back a fresh package install"

    if [ "$expected_status" = success ]; then
        [ -e "$case_root/patch-phase" ] ||
            fail_test "$scenario did not proceed to the subscription patch phase"
    else
        [ ! -e "$case_root/patch-phase" ] ||
            fail_test "$scenario proceeded to the subscription patch phase after official installer failure"
    fi
}

run_case supported 0.7.22 success
run_case unsupported 0.8.0 failure
run_case failure 0.7.22 failure
run_case stale 0.7.20 failure

forced_stale_root="$test_root/forced-stale-update"
mkdir -p "$forced_stale_root/tmp"
if (
    tmp_dir="$forced_stale_root/tmp"
    backup_dir=""
    persistent_backup_dir=""
    rollback_dir=""
    rollback_generation=""
    backup_complete=0
    restore_on_fail=0
    restore_done=0
    transaction_phase="preflight"
    PODKOP_PATCH_UPDATE_PODKOP=1
    PODKOP_PATCH_FORCE_PODKOP_UPDATE=1
    PODKOP_PATCH_TARGET_PODKOP_VERSION=0.7.22

    podkop_runtime_exists() { return 0; }
    podkop_persistent_state_exists() { return 0; }
    current_podkop_version() { printf '%s\n' 0.7.20; }
    latest_official_podkop_version() { printf '%s\n' 0.7.22; }
    update_manager_v1_requested_podkop_upgrade() { return 1; }
    download() { : > "$2"; }
    installed_package_version() {
        printf '%s\n' 0.7.20
    }
    uci() { return 0; }
    backup_persistent_paths() {
        backup_dir="$forced_stale_root/persistent-backup"
        persistent_backup_dir="$backup_dir"
        mkdir -p "$backup_dir"
        : > "$forced_stale_root/persistent-backup-called"
    }
    run_official_podkop_installer() {
        : > "$forced_stale_root/official-called"
        return 0
    }
    restore_runtime() {
        : > "$forced_stale_root/restore-called"
        restore_done=1
    }
    restore_missing_persistent_paths() { :; }

    update_official_podkop_if_requested
) > "$forced_stale_root/output" 2>&1; then
    fail_test 'forced update accepted an older supported Podkop version after the official installer reported success'
fi
[ -e "$forced_stale_root/persistent-backup-called" ] &&
    [ -e "$forced_stale_root/official-called" ] &&
    [ ! -e "$forced_stale_root/restore-called" ] ||
    fail_test 'forced stale-version update did not preserve config, invoke the installer, and avoid unsafe runtime rollback'

grep -q 'official Podkop installed unsupported version 0.8.0' "$test_root/unsupported/output" &&
    grep -q 'Subscription URLTest patch was not applied' "$test_root/unsupported/output" ||
    fail_test 'unsupported fresh version did not report that the patch was withheld'
grep -q 'official Podkop installation failed' "$test_root/failure/output" ||
    fail_test 'failed fresh official installation did not report an error'
grep -q 'below target 0.7.22' "$test_root/stale/output" &&
    grep -q 'Subscription URLTest patch was not applied' "$test_root/stale/output" ||
    fail_test 'stale fresh Podkop version did not report that the target was missed and the patch was withheld'

cmp -s "$repo_root/i" "$repo_root/openwrt/install.sh" ||
    fail_test 'root and OpenWrt installers are not byte-identical'

printf '%s\n' 'PASS: unified command installs Podkop first and gates the patch on a supported result'
