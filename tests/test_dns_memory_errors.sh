#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir "$db_work"
PODKOP_DIAG_UPTIME_FILE="$work/uptime"
PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
PODKOP_DIAG_MEMDOC_FILE="$work/memdoc"
printf '100.0 0\n' > "$work/uptime"
db_light_collect() { fail 'unsafe admission reached DNS probes'; }
db_light_fingerprint() { fail 'unsafe admission reached graph preparation'; }
db_benchmark() { fail 'unsafe admission reached endpoint benchmark'; }
for action in db_light_select db_light_manual db_quick_benchmark; do
    printf 'MemAvailable: 52632 kB\n' > "$work/meminfo"
    printf 'THRESHOLD=$UNKNOWN\n' > "$work/memdoc"
    if "$action"; then fail 'unreadable policy accepted'; fi
    jq -e '.error=="memory_policy_unreadable"' "$DB_STATUS" >/dev/null || fail "$action calls unreadable policy low memory"
    printf 'THRESHOLD=20000\nTHRESHOLD=3000\n' > "$work/memdoc"
    printf 'MemAvailable: 36383 kB\n' > "$work/meminfo"
    if "$action"; then fail 'low memory accepted'; fi
    jq -e '.error=="insufficient_memory"' "$DB_STATUS" >/dev/null || fail "$action lost real shortage"
    printf 'MemAvailable: broken kB\n' > "$work/meminfo"
    if "$action"; then fail 'unknown memory accepted'; fi
    jq -e '.error=="memory_status_unavailable"' "$DB_STATUS" >/dev/null || fail "$action calls unknown RAM a shortage"
done
echo 'PASS: DNS selection, manual pair and endpoint benchmark separate policy/read failures from low RAM'
