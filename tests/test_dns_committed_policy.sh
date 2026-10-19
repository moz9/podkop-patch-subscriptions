#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-snapshot.sh"
uci() {
 [ "$1" = -q ] && [ "$2" = export ] || return 1
 case "$3" in podkop) echo 'package podkop';; /proc/self/fd/3) echo 'package 3';; *) return 1;; esac
 printf "config settings 'settings'\n option dns_type 'udp'\n"
}
original="$(subscription_services_snapshot_policy_hash)"
printf "config settings 'settings'\n" > "$work/committed"
PODKOP_DNS_COMMITTED_FILE="$work/committed"
[ "$original" = "$(subscription_services_snapshot_policy_hash)" ] || { echo 'FAIL: committed FD changed policy identity' >&2; exit 1; }
echo 'PASS: committed-only UCI policy retains package identity'
