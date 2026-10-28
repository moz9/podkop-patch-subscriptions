#!/bin/sh
# Catches falling back to installer/package update for opted-in file-only releases.
# Generated library supplies globals and invokes the transport callbacks.
# shellcheck disable=SC1091,SC2034,SC2317
set -eu
root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
sed -e "s|^STATE_DIR=\"/tmp/podkop-update-manager\"$|STATE_DIR=\"$tmp/bootstrap\"|" -e '/^case "$1" in/,$d' "$root/openwrt/podkop-update-manager" > "$tmp/manager"
. "$tmp/manager"
STATE_DIR="$tmp/state"; mkdir "$STATE_DIR"
STATUS_FILE="$STATE_DIR/status.json"; DETAILS_FILE="$STATE_DIR/details.json"; LOG_FILE="$STATE_DIR/update.log"; LOCK_DIR="$STATE_DIR/lock"
fail() { echo "FAIL: $*" >&2; exit 1; }
printf '20261028-pe-v40\n' > "$tmp/current"
current_podkop_version() { echo 0.7.24; }
current_patch_version() { cat "$tmp/current"; }
cat > "$tmp/adapter" <<EOF
#!/bin/sh
case "\$1" in check) exit 0;; apply) echo adapter >> '$tmp/calls'; jq -r '.patchVersion' "\$2" > '$tmp/current';; *) exit 1;; esac
EOF
hash="$(sha256sum "$tmp/adapter"|cut -d' ' -f1)"
jq -cn --arg hash "$hash" '{schemaVersion:1,channel:"podkop-pe",supportedPodkopVersions:["0.7.24"],recommendedPodkopVersion:"0.7.24",engineVersion:"1.14.2-pdk-r14",patchVersion:"20261028-pe-v41",releaseStatus:"released",pinnedCommit:"0123456789abcdef0123456789abcdef01234567",routerdeskPatch:{schemaVersion:1,mode:"files-only",luciFilesOnly:1},sha256:{"openwrt/podkop-pe-luci-update":$hash}}' > "$tmp/manifest"
download_file() {
    case "$1" in
      "$MANIFEST_URL"*) cp "$tmp/manifest" "$2";;
      "$RELEASE_URL") printf '{"tag_name":"0.7.24"}\n' > "$2";;
      https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/0123456789abcdef0123456789abcdef01234567/openwrt/podkop-pe-luci-update) cp "$tmp/adapter" "$2";;
      *) fail "forbidden/unpinned download: $1";;
    esac
}
curl() {
    local transport_url
    for transport_url do :; done
    case "$transport_url" in
        https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/0123456789abcdef0123456789abcdef01234567/openwrt/podkop-pe-luci-update) cat "$tmp/adapter";;
        *) fail "forbidden/unpinned adapter transport: $transport_url";;
    esac
}
run_with_timeout() { shift; "$@"; }
perform_check 0
jq -e '.canUpdate==true and .updateMode=="patch"' "$DETAILS_FILE" >/dev/null || fail 'opted-in pinned PE24 files-only update remains blocked'
perform_update
[ "$(cat "$tmp/calls")" = adapter ] || fail wrong-update-path
jq -e '.state=="success" and .currentPatchVersion=="20261028-pe-v41"' "$STATUS_FILE" >/dev/null || fail missing-update-receipt
printf '20261028-pe-v40\n' > "$tmp/current"
jq '.routerdeskPatch.luciFilesOnly=0' "$tmp/manifest" > "$tmp/next"; mv "$tmp/next" "$tmp/manifest"
perform_check 0
jq -e '.canUpdate==false and .message=="routerdesk_update_required"' "$DETAILS_FILE" >/dev/null || fail no-opt-in-bypass
jq '.routerdeskPatch.luciFilesOnly=1|.pinnedCommit="main"' "$tmp/manifest" > "$tmp/next"; mv "$tmp/next" "$tmp/manifest"
perform_check 0
jq -e '.canUpdate==false' "$DETAILS_FILE" >/dev/null || fail unpinned-bypass
# Run the production bootstrap downloader with an oversized/chunked transport,
# not the generic download stub above. Record bytes before refusal/cleanup so
# deleting a fully downloaded oversized response cannot masquerade as a bound.
(
    eval "$(sed -n '/^download_file() {$/,/^}$/p' "$root/openwrt/podkop-update-manager")"
    jq '.pinnedCommit="0123456789abcdef0123456789abcdef01234567"' "$tmp/manifest" > "$STATE_DIR/manifest.json"
    curl() {
        local transport_output='' transport_result
        while [ "$#" -gt 0 ]; do
            case "$1" in -o) shift; transport_output="$1";; esac
            shift
        done
        if [ -n "$transport_output" ]; then head -c 4194304 /dev/zero > "$transport_output"
        else head -c 4194304 /dev/zero; fi
        transport_result=$?
        wc -c < "$STATE_DIR/pe-luci-adapter.sh" >> "$tmp/observed-bytes"
        return "$transport_result"
    }
    if prepare_pe_luci_adapter; then fail oversized-adapter-accepted; fi
    [ -s "$tmp/observed-bytes" ] || fail missing-transport-observation
    awk '$1>2097153 {bad=1} END {exit bad}' "$tmp/observed-bytes" || fail unbounded-adapter-bootstrap
)
echo 'PASS: PE24 manager uses pinned opt-in adapter, never installer, and retains bootstrap refusal without opt-in/pin'
