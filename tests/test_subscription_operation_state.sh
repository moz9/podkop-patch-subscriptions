#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-subscription-sources.sh"
sed -n '/^subscription_runtime_busy() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop" > "$work/busy"
. "$work/busy"
subscription_action_lock_busy() { [ "${locked:-0}" = 1 ]; }
subscription_reload_pending_file() { echo "$work/pending"; }
ps() { printf '%s\n' "${worker:-}"; }
get_subscription_operation_status | jq -e '.busy==false and .pending==false' >/dev/null
locked=1
get_subscription_operation_status | jq -e '.busy and .retryAfter>0' >/dev/null
locked=0; worker='123 root /bin/sh /usr/bin/podkop reload'
get_subscription_operation_status | jq -e '.busy' >/dev/null
worker=''; touch "$work/pending"
get_subscription_operation_status | jq -e '.busy==false and .pending' >/dev/null
echo 'PASS: operation status follows live locks/workers and pending activation'
