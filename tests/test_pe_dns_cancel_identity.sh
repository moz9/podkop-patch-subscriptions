#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
production=''; coordinator=''
trap 'kill ${production:-} ${coordinator:-} 2>/dev/null || true; rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; mkdir "$DB_LOCK"
status() { jq -cn --argjson pid "$1" '{state:"running",action:"recommend_verified",pid:$pid}' > "$DB_STATUS"; }
sleep 30 & production=$!
printf '%s\n' "$production" > "$DB_LOCK/owner"
printf '%s:stale-starttime\n' "$production" > "$DB_LOCK/identity"
status "$production"; db_cancel >/dev/null
sleep 0.1
kill -0 "$production" 2>/dev/null || fail 'stale report killed foreign production PID'
command -v db_coordinator_identity >/dev/null || fail 'coordinator identity absent'
db_coordinator_identity "$production" > "$DB_LOCK/identity"
status "$production"; db_cancel >/dev/null
kill -0 "$production" 2>/dev/null || fail 'matching starttime but foreign argv killed'
DB_SELF="$work/coordinator.sh"
printf '#!/bin/sh\ntrap "exit 0" TERM\nwhile :; do sleep 1; done\n' > "$DB_SELF"
sh "$DB_SELF" __worker recommend_verified & coordinator=$!
printf '%s\n' "$coordinator" > "$DB_LOCK/owner"
printf '%s:wrong-starttime\n' "$coordinator" > "$DB_LOCK/identity"
status "$coordinator"; db_cancel >/dev/null
kill -0 "$coordinator" 2>/dev/null || fail 'reused coordinator PID was signalled'
db_coordinator_identity "$coordinator" > "$DB_LOCK/identity"
printf '%s\n' "$production" > "$DB_LOCK/owner"
status "$coordinator"; db_cancel >/dev/null
kill -0 "$coordinator" 2>/dev/null || fail 'coordinator without lock ownership was signalled'
printf '%s\n' "$coordinator" > "$DB_LOCK/owner"
status "$coordinator"; db_cancel >/dev/null
wait "$coordinator"
kill -0 "$production" 2>/dev/null || fail 'valid cancellation changed production'
echo 'PASS: real coordinator cancellation, foreign argv and reused PID remain alive'
