#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo/i" > "$work/installer"
. "$work/installer"
[ "$PODKOP_PATCH_TARGET_PODKOP_VERSION" = 0.7.24 ] || fail_test 'adapter does not target 0.7.24'
[ "$PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS" = 0.7.24 ] || fail_test 'legacy/current production version admitted'
pe_engine_version_output() { printf 'sing-box version %s\nFeatures: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link,tls.utls-fallback\n' "$engine_identity"; }
engine_identity=1.14.2-pdk-r14
pe_engine_usable || fail_test 'pinned Engine rejected'
for engine_identity in 1.13.21-pdk-r14 1.14.2-pdk-r13 1.14.3-pdk-r14 1.15.0-pdk-r14; do
    if pe_engine_usable; then fail_test "unverified Engine accepted: $engine_identity"; fi
done
engine_identity=1.14.2-pdk-r14
current_podkop_version() { printf '%s\n' "$current"; }
podkop_packages_match_runtime() { [ "$1" = "$current" ]; }
current=0.7.24
update_official_podkop_if_requested || fail_test 'matching installed packages rejected'
apk() { printf '%s\n' "$*" >> "$work/package-writes"; return 91; }
opkg() { printf '%s\n' "$*" >> "$work/package-writes"; return 91; }
download() { printf '%s\n' "$*" >> "$work/downloads"; return 91; }
uci() { printf '%s\n' "$*" >> "$work/uci-events"; return 91; }
for current in '' 0.7.22 0.7.23; do
    if (update_official_podkop_if_requested) > "$work/error" 2>&1; then fail_test "unprepared migration accepted: $current"; fi
    grep -q 'separate verified package migration' "$work/error" || fail_test 'wrong migration refusal'
done
current=0.7.24; engine_identity=1.13.21-pdk-r11
if (update_official_podkop_if_requested) > "$work/error" 2>&1; then fail_test 'old Engine upgraded automatically'; fi
if (pe_install_pinned_packages) > "$work/error" 2>&1; then fail_test 'prepared installer still mutates packages'; fi
[ ! -e "$work/package-writes" ] && [ ! -e "$work/downloads" ] && [ ! -e "$work/uci-events" ] || fail_test 'refusal caused package/UCI/network mutations'

# Run the real manager decision with only its network/appliance boundaries replaced.
sed -e 's/\r$//' -e '/^case "$1" in/,$d' "$repo/openwrt/podkop-update-manager" > "$work/manager"
. "$work/manager"
STATE_DIR="$work/state"; mkdir -p "$STATE_DIR"
DETAILS_FILE="$STATE_DIR/details.json"; STATUS_FILE="$STATE_DIR/status.json"; LOG_FILE="$STATE_DIR/log"
MANIFEST_URL=fixture-manifest; RELEASE_URL=fixture-release
download_file() {
    case "$1" in fixture-manifest*) jq '.releaseStatus="prepared"' "$repo/openwrt/update-manifest.json" > "$2";; fixture-release) printf '{"tag_name":"0.7.24"}\n' > "$2";; *) return 91;; esac
}
current_podkop_version() { printf '0.7.23\n'; }
current_patch_version() { printf '20261010-pe-v13\n'; }
perform_check 0 || fail_test 'prepared manifest rejected'
jq -e '.canUpdate==false and .updateMode=="blocked" and .message=="prepared_not_released"' "$DETAILS_FILE" >/dev/null || fail_test 'prepared release enabled remote update'
perform_update || fail_test 'prepared update boundary returned an unexpected failure'
jq -e '.state=="blocked" and .message=="prepared_not_released"' "$STATUS_FILE" >/dev/null || fail_test 'prepared update was not blocked'
[ ! -e "$STATE_DIR/installer.sh" ] || fail_test 'prepared update fetched an installer'
cmp "$repo/i" "$repo/openwrt/install.sh" || fail_test 'installer copies diverged'
printf '%s\n' 'PASS: 0.7.24/Engine identity and preparation-only package/update boundaries'
