#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-subscription-sources.sh"
sed -n '/^subscription_runtime_busy() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop" > "$work/busy"
. "$work/busy"
sed -n '/^subscription_pending_sections_json() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop" > "$work/pending-functions"
. "$work/pending-functions"
for hook in podkop_section_root podkop_section_single_mode; do
    eval "$(sed -n "/^$hook() {/p" "$repo/openwrt/podkop-section-hooks.sh")"
done
PODKOP_SECTION_ROOT="$work/section"
mkdir "$PODKOP_SECTION_ROOT"
subscription_action_lock_busy() { [ "${locked:-0}" = 1 ]; }
subscription_reload_pending_file() { echo "$work/pending"; }
ps() { printf '%s\n' "${worker:-}"; }
get_subscription_operation_status | jq -e '.busy==false and .pending==false and .pendingSections==[]' >/dev/null
locked=1
get_subscription_operation_status | jq -e '.busy and .retryAfter>0' >/dev/null
locked=0; worker='123 root /bin/sh /usr/bin/podkop reload'
get_subscription_operation_status | jq -e '.busy' >/dev/null
worker=''; touch "$work/pending"
get_subscription_operation_status | jq -e '.busy==false and .pending' >/dev/null
podkop_section_enabled() { return 0; }
podkop_section_names() { printf '["main","peer"]\n'; }
podkop_section_name() { printf 'main\n'; }
podkop_section_ready() { return 0; }
get_subscription_operation_status | jq -e '.pendingSections==["main","peer"]' >/dev/null
printf '["peer"]\n' > "$work/pending"
get_subscription_operation_status | jq -e '.pendingSections==["peer"] and .isolatedReady' >/dev/null
printf 'single\n' > "$PODKOP_SECTION_ROOT/runtime-mode"
podkop_section_manager() { printf '{"ready":true,"sections":[{"section":"main","ready":true},{"section":"peer","ready":true}]}\n'; }
get_subscription_operation_status | jq -e '.runtimeMode=="single" and .pendingSections==["peer"] and .isolatedSections==["main","peer"] and .isolatedReady and (.sections|length)==2' >/dev/null
echo 'PASS: operation status follows live locks/workers and pending activation'
