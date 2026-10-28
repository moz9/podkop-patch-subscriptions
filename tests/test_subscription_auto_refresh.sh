#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
version="$(jq -er '.recommendedPodkopVersion' "$root/openwrt/update-manifest.json")"
runtime="$root/openwrt/runtime-$version/usr/bin/podkop"
# PE 0.7.23 has no section-hook integration. This compatibility line must keep
# downloaded catalogs pending instead of simulating Legacy/PE0.7.24 hooks.
if grep -Fq '. /usr/lib/podkop/section-hooks.sh' "$runtime"; then
    echo 'FAIL: PE0.7.23 unexpectedly gained section integration; review its acceptance contract'; exit 1
fi
sed -n '/^# subscription_seamless_reload begin$/,/^# subscription_seamless_reload end$/p' "$runtime" > "$tmp/block"
. "$tmp/block"
uci() { printf '%s' "$drafts"; }
podkop_section_preflight() { echo preflight >> "$tmp/calls"; return 1; }
podkop_section_apply() { echo applied >> "$tmp/calls"; return 1; }
config_get() { echo global_reload >> "$tmp/calls"; return 1; }
sing_box_init_config() { echo rebuilt >> "$tmp/calls"; return 1; }
subscription_signal_sing_box_reload() { echo signaled >> "$tmp/calls"; return 1; }
subscription_reload_pending_file() { echo "$tmp/pending"; }
echolog() { :; }
SUBSCRIPTION_UPDATE_TARGET=main; SUBSCRIPTION_FAILED_SECTIONS=0
if command -v podkop_section_enabled >/dev/null; then
    echo 'FAIL: fixture must not invent unavailable section hooks'; exit 1
fi
for drafts in '' changed; do
    subscription_reload_seamless || { echo 'FAIL: unsupported scoped refresh did not defer'; exit 1; }
    test -f "$tmp/pending" || { echo 'FAIL: deferred catalog marker missing'; exit 1; }
    test ! -f "$tmp/calls" || { echo 'FAIL: unavailable scoped hooks caused runtime mutation'; exit 1; }
done
echo 'PASS: PE0.7.23 without scoped hooks defers refreshed catalogs and preserves runtime/drafts; scoped automatic activation is unsupported'
