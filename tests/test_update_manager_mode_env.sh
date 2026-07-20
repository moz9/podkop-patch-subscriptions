#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
manager="$repo_root/openwrt/podkop-update-manager"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM

manager_functions="$test_root/podkop-update-manager-functions.sh"
sed \
    -e 's/\r$//' \
    -e "s|^STATE_DIR=\"/tmp/podkop-update-manager\"$|STATE_DIR=\"$test_root/bootstrap-state\"|" \
    -e '/^case "$1" in/,$d' \
    "$manager" > "$manager_functions"
. "$manager_functions"

STATE_DIR="$test_root/state"
STATUS_FILE="$STATE_DIR/status.json"
DETAILS_FILE="$STATE_DIR/details.json"
LOG_FILE="$STATE_DIR/update.log"
LOCK_DIR="$STATE_DIR/lock"
CAPTURE_FILE="$test_root/installer-argv"
mkdir -p "$STATE_DIR"

write_status() { :; }
log_line() { :; }
download_file() {
    printf '#!/bin/sh\nexit 0\n' > "$2"
}
run_with_timeout() {
    shift
    printf '%s\n' "$@" > "$CAPTURE_FILE"
}
current_podkop_version() {
    printf '%s\n' "$RESULT_PODKOP_VERSION"
}
current_patch_version() {
    printf '%s\n' "$RESULT_PATCH_VERSION"
}

set_check_result() {
    TEST_MODE="$1"
    TEST_CURRENT_PODKOP="$2"
    TEST_LATEST_PODKOP="$3"
    TEST_CURRENT_PATCH="$4"
    TEST_LATEST_PATCH="$5"
}

perform_check() {
    podkop_update=false
    [ "$TEST_CURRENT_PODKOP" = "$TEST_LATEST_PODKOP" ] || podkop_update=true
    jq -cn \
        --arg updateMode "$TEST_MODE" \
        --arg currentPodkopVersion "$TEST_CURRENT_PODKOP" \
        --arg latestPodkopVersion "$TEST_LATEST_PODKOP" \
        --arg currentPatchVersion "$TEST_CURRENT_PATCH" \
        --arg latestPatchVersion "$TEST_LATEST_PATCH" \
        --argjson podkopUpdateAvailable "$podkop_update" \
        '{updateMode:$updateMode,canUpdate:true,currentPodkopVersion:$currentPodkopVersion,latestPodkopVersion:$latestPodkopVersion,currentPatchVersion:$currentPatchVersion,latestPatchVersion:$latestPatchVersion,podkopUpdateAvailable:$podkopUpdateAvailable}' \
        > "$DETAILS_FILE"
}

set_check_result podkop_and_patch 0.7.20 0.7.21 patch-v1 patch-v1
RESULT_PODKOP_VERSION=0.7.21
RESULT_PATCH_VERSION=patch-v1
perform_update

if ! grep -Fxq 'PODKOP_PATCH_FORCE_PODKOP_UPDATE=1' "$CAPTURE_FILE"; then
    printf '%s\n' 'FAIL: podkop_and_patch did not force the requested official Podkop update' >&2
    printf '%s\n' 'Captured installer arguments:' >&2
    sed 's/^/  /' "$CAPTURE_FILE" >&2
    exit 1
fi

set_check_result patch 0.7.21 0.7.21 patch-v1 patch-v2
RESULT_PODKOP_VERSION=0.7.21
RESULT_PATCH_VERSION=patch-v2
perform_update

if ! grep -Fxq 'PODKOP_PATCH_UPDATE_PODKOP=1' "$CAPTURE_FILE" ||
    ! grep -Fxq 'PODKOP_PATCH_FORCE_PODKOP_UPDATE=0' "$CAPTURE_FILE"; then
    printf '%s\n' 'FAIL: patch-only mode did not explicitly disable the forced official Podkop update' >&2
    printf '%s\n' 'Captured installer arguments:' >&2
    sed 's/^/  /' "$CAPTURE_FILE" >&2
    exit 1
fi

printf '%s\n' 'PASS: updater mode selects the correct Podkop force policy'
