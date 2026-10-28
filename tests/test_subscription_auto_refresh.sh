#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed -n '/^# subscription_seamless_reload begin$/,/^# subscription_seamless_reload end$/p' "$root/openwrt/runtime-0.7.22/usr/bin/podkop" > "$tmp/block"
. "$tmp/block"
subscription_pending_sections_json() { echo '["main","GEOBLOCK"]'; }
podkop_section_names() { echo '["main"]'; }
podkop_section_enabled() { return 0; }
subscription_required_services_json() { printf '%s\n' "$services"; }
uci() { printf '%s' "$drafts"; }
podkop_section_preflight() { PODKOP_SECTION_TARGET=main; return 0; }
podkop_section_apply() { echo applied >> "$tmp/calls"; return "$apply_status"; }
subscription_pending_clear() { echo "$1" > "$tmp/cleared"; }
subscription_reload_pending_file() { echo "$tmp/pending"; }
subscription_pending_mark() { touch "$tmp/pending"; }
echolog() { :; }
services='[]'; drafts=''; apply_status=0
SUBSCRIPTION_UPDATE_TARGET=main; SUBSCRIPTION_FAILED_SECTIONS=0
subscription_reload_seamless
test -f "$tmp/calls" || { echo 'FAIL: unfiltered refresh did not activate saved pool'; exit 1; }
test "$(cat "$tmp/cleared")" = main
test ! -f "$tmp/pending" || { echo 'FAIL: successful refresh recreated pending marker'; exit 1; }
rm "$tmp/calls" "$tmp/cleared"
services='["chatgpt"]'
subscription_reload_seamless
test ! -f "$tmp/calls" || { echo 'FAIL: service gate bypassed'; exit 1; }
services='[]'; drafts=changed
subscription_reload_seamless
test ! -f "$tmp/calls" || { echo 'FAIL: unrelated draft applied'; exit 1; }
drafts=''; apply_status=1
if subscription_reload_seamless; then echo 'FAIL: apply failure hidden'; exit 1; fi
echo 'PASS: saved unfiltered refresh applies; service gates and drafts preserved; failures reported'
