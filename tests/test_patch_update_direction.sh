#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM

manager_functions="$test_root/podkop-update-manager-functions.sh"
sed \
    -e 's/\r$//' \
    -e "s|^STATE_DIR=\"/tmp/podkop-update-manager\"$|STATE_DIR=\"$test_root/state\"|" \
    -e '/^case "$1" in/,$d' \
    "$repo_root/openwrt/podkop-update-manager" > "$manager_functions"
. "$manager_functions"

expect_update() {
    current="$1"
    latest="$2"
    if ! patch_update_available "$current" "$latest"; then
        printf 'FAIL: expected patch update: %s -> %s\n' "${current:-none}" "$latest" >&2
        exit 1
    fi
}

expect_no_update() {
    current="$1"
    latest="$2"
    if patch_update_available "$current" "$latest"; then
        printf 'FAIL: unexpected patch downgrade/update: %s -> %s\n' "$current" "$latest" >&2
        exit 1
    fi
}

expect_update '' '20260720-update-center-force-v1'
expect_no_update '20260720-update-center-force-v1' '20260720-update-center-force-v1'
expect_update '20260720-update-center-force-v1' '20260813-reliability-responsive-v1'
expect_no_update '20260813-reliability-responsive-v1' '20260720-update-center-force-v1'
expect_update '20260813-reliability-responsive-v1' '20260813-reliability-responsive-v2'
expect_no_update '20260813-reliability-responsive-v2' '20260813-reliability-responsive-v1'
expect_update '20260813-reliability-responsive-v2' '20260813-reliability-responsive-v3'
expect_no_update '20260813-reliability-responsive-v3' '20260813-reliability-responsive-v2'
expect_update '20260813-reliability-responsive-v3' '20260813-reliability-responsive-v4'
expect_no_update '20260813-reliability-responsive-v4' '20260813-reliability-responsive-v3'
expect_update '20260813-reliability-responsive-v4' '20260814-google-play-guard-v1'
expect_no_update '20260814-google-play-guard-v1' '20260813-reliability-responsive-v4'
expect_update 'legacy-marker' '20260813-reliability-responsive-v1'
expect_no_update '20260813-reliability-responsive-v1' 'legacy-marker'
expect_update 'legacy-marker-v1' 'legacy-marker-v2'

mkdir -p "$STATE_DIR"
fixture_manifest="$test_root/fixture-manifest.json"
fixture_release="$test_root/fixture-release.json"
TEST_CURRENT_PODKOP='0.7.21'
TEST_CURRENT_PATCH='20260813-reliability-responsive-v1'

current_podkop_version() {
    printf '%s\n' "$TEST_CURRENT_PODKOP"
}

current_patch_version() {
    printf '%s\n' "$TEST_CURRENT_PATCH"
}

download_file() {
    url="$1"
    destination="$2"
    case "$url" in
    *api.github.com*) cp "$fixture_release" "$destination" ;;
    *)
        case "$destination" in
        *installer.sh) INSTALLER_DOWNLOAD_ATTEMPTED=1 ;;
        esac
        cp "$fixture_manifest" "$destination"
        ;;
    esac
}

cat > "$fixture_manifest" <<'JSON'
{"schemaVersion":1,"patchVersion":"20260720-update-center-force-v1","supportedPodkopVersions":["0.7.21","0.7.22"]}
JSON
printf '%s\n' '{"tag_name":"v0.7.21"}' > "$fixture_release"

perform_check 1
if ! jq -e '.updateMode == "none" and .canUpdate == false and .message == "up_to_date" and .patchUpdateAvailable == false' "$STATUS_FILE" >/dev/null; then
    printf 'FAIL: the exact newer-installed-patch scenario was reported as an update\n' >&2
    cat "$STATUS_FILE" >&2
    exit 1
fi

printf '%s\n' '{"tag_name":"v0.7.22"}' > "$fixture_release"

perform_check 1
if ! jq -e '.updateMode == "blocked" and .canUpdate == false and .message == "published_patch_older" and .patchUpdateAvailable == false' "$STATUS_FILE" >/dev/null; then
    printf 'FAIL: a Podkop update could downgrade a newer installed patch\n' >&2
    cat "$STATUS_FILE" >&2
    exit 1
fi

INSTALLER_DOWNLOAD_ATTEMPTED=0
perform_update
if [ "$INSTALLER_DOWNLOAD_ATTEMPTED" != 0 ] ||
    ! jq -e '.state == "blocked" and .message == "published_patch_older"' "$STATUS_FILE" >/dev/null; then
    printf 'FAIL: direct update did not preserve the downgrade block\n' >&2
    cat "$STATUS_FILE" >&2
    exit 1
fi

cat > "$fixture_manifest" <<'JSON'
{"schemaVersion":1,"patchVersion":"","supportedPodkopVersions":["0.7.21"]}
JSON
if perform_check 1; then
    printf 'FAIL: an empty patch version was accepted as a valid manifest\n' >&2
    exit 1
fi
if ! jq -e '.state == "error" and .message == "manifest_failed"' "$STATUS_FILE" >/dev/null; then
    printf 'FAIL: invalid manifest did not publish manifest_failed\n' >&2
    cat "$STATUS_FILE" >&2
    exit 1
fi

printf '%s\n' 'PASS: patch update direction rejects older manifests and accepts real upgrades'
