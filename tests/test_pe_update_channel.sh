#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sed -e 's/\r$//' -e "s|^STATE_DIR=\"/tmp/podkop-update-manager\"$|STATE_DIR=\"$work/state\"|" -e '/^case "$1" in/,$d' "$repo/openwrt/podkop-update-manager" > "$work/manager"
. "$work/manager"
current_podkop_version() { echo 0.7.24; }
current_patch_version() { echo 20261019-pe-v21-routerdesk; }
download_file() {
    case "$1" in
      https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/podkop-pe-0.7.24/openwrt/update-manifest.json\?*)
        [ "${network_failure:-0}" = 0 ] || return 1
        jq '.patchVersion="20261019-pe-v22-routerdesk"' "$repo/openwrt/update-manifest.json" > "$2";;
      https://api.github.com/repos/itdoginfo/podkop/releases/tags/0.7.24) printf '{"tag_name":"0.7.24"}\n' > "$2";;
      *) return 1;;
    esac
}
perform_check 1 || fail 'PE24 manager requested an obsolete manifest channel'
jq -e '.state=="ready" and .currentPodkopVersion=="0.7.24" and .currentPatchVersion=="20261019-pe-v21-routerdesk" and .latestPatchVersion=="20261019-pe-v22-routerdesk" and .patchUpdateAvailable==true and .canUpdate==false and .message=="routerdesk_update_required"' "$STATUS_FILE" >/dev/null || fail 'file-only update not accurately presented'
perform_update || fail 'RouterDesk-only update refusal'
[ ! -f "$STATE_DIR/installer.sh" ] || fail 'LuCI invoked package installer on files-only channel'
network_failure=1
! perform_check 1 || fail 'network failure accepted'
jq -e '.state=="error" and .canUpdate==false and .currentPodkopVersion=="0.7.24" and .currentPatchVersion=="20261019-pe-v21-routerdesk" and (.latestPatchVersion//"")=="" and .patchUpdateAvailable==false' "$STATUS_FILE" >/dev/null || fail 'failed check retained stale versions/update permission'
current_patch_version() { echo 20261019-pe-v22-routerdesk; }
show_status > "$work/reopened.json"
jq -e '.state=="idle" and .currentPatchVersion=="20261019-pe-v22-routerdesk" and .canUpdate==false and (.latestPatchVersion//"")==""' "$work/reopened.json" >/dev/null || fail 'opening after RouterDesk update retained old error/version'
network_failure=0
perform_check 1 || fail 'installed v22 check'
jq -e '.message=="up_to_date" and .updateMode=="none" and .patchUpdateAvailable==false and .canUpdate==false' "$STATUS_FILE" >/dev/null || fail 'current files-only version falsely blocked'
patch_update_available 20261019-pe-v21-routerdesk 20261019-pe-v22-routerdesk || fail 'same-day revision ignored'
! patch_update_available 20261019-pe-v22-routerdesk 20261019-pe-v21-routerdesk || fail 'downgrade offered'
echo 'PASS: PE24 channel, RouterDesk-only update, current state and fail-closed fresh version display'
