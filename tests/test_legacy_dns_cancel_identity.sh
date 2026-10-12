#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; mkdir "$DB_LOCK"
kill() { if [ "${1:-}" = -0 ]; then command kill "$@"; else printf '%s\n' "$*" >> "$work/signals"; fi; }
status() { jq -cn --argjson pid "$$" '{state:"running",action:"recommend_verified",pid:$pid}' > "$DB_STATUS"; }
printf '%s\n' "$$" > "$DB_LOCK/owner"
printf '%s\n' "$$:stale-starttime" > "$DB_LOCK/identity"
status; db_cancel >/dev/null
[ ! -s "$work/signals" ] || fail 'stale report signalled a reused foreign PID'
command -v db_coordinator_identity >/dev/null || fail 'coordinator starttime identity missing'
db_coordinator_identity() { printf '%s:123\n' "$1"; }
printf '%s:123\n' "$$" > "$DB_LOCK/identity"
status; db_cancel >/dev/null
[ ! -s "$work/signals" ] || fail 'matching starttime but foreign cmdline was signalled'
db_coordinator_cmdline() { [ "$2" = recommend_verified ]; }
printf '%s\n' 999999 > "$DB_LOCK/owner"
status; db_cancel >/dev/null
[ ! -s "$work/signals" ] || fail 'process without matching lock ownership was signalled'
printf '%s\n' "$$" > "$DB_LOCK/owner"
status; db_cancel >/dev/null
[ "$(cat "$work/signals")" = "$$" ] || fail 'owned matching coordinator was not cancelled'
echo 'PASS: DNS cancel requires lock owner, starttime identity and exact coordinator command'
