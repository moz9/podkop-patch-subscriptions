#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
sed -e 's/\r$//' -e "s|^STATE_DIR=.*$|STATE_DIR=\"$work/state\"|" -e '/^case "$1" in/,$d' \
    "$repo/openwrt/podkop-update-manager" > "$work/manager.sh"
. "$work/manager.sh"
log_line() { :; }
write_status() { :; }
current_podkop_version() { printf '%s\n' "$installed"; }
current_patch_version() { printf '%s\n' 20261010-old-v1; }
download_file() {
    case "$1" in
        "$MANIFEST_URL"*) cp "$work/manifest" "$2";;
        "$RELEASE_URL"*) printf '{"tag_name":"%s"}\n' "$upstream" > "$2";;
        *) return 1;;
    esac
}
installed="$(jq -r '.recommendedPodkopVersion' "$repo/openwrt/update-manifest.json")"
upstream="$installed"
[ "$installed" != 0.7.22 ] || upstream=0.7.24
cp "$repo/openwrt/update-manifest.json" "$work/manifest"
perform_check 0
if [ "$installed" = 0.7.24 ]; then
    jq -e '.canUpdate==false and .message=="routerdesk_update_required"' "$DETAILS_FILE" >/dev/null
else
    jq -e '.canUpdate and .updateMode=="patch" and .patchUpdateAvailable and (.podkopUpdateAvailable|not)' "$DETAILS_FILE" >/dev/null || {
        printf '%s\n' 'FAIL: supported patch update is blocked by an incompatible upstream base' >&2; exit 1;
    }
fi
# A manifest for another engine/base must never authorize an installation.
if [ "$installed" = 0.7.24 ]; then other=0.7.23; else other=0.7.24; fi
jq --arg other "$other" '.supportedPodkopVersions=[$other] | .recommendedPodkopVersion=$other' \
    "$repo/openwrt/update-manifest.json" > "$work/manifest"
if perform_check 0; then
    jq -e '(.canUpdate|not) and .updateMode=="blocked"' "$DETAILS_FILE" >/dev/null
else
    jq -e '(.canUpdate|not) and (.patchUpdateAvailable|not)' "$DETAILS_FILE" >/dev/null || {
        printf '%s\n' 'FAIL: rejected channel retained an old installation authorization' >&2; exit 1;
    }
fi
printf '%s\n' 'PASS: own patch channel remains available; another base cannot authorize installation'
