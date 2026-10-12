#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; unrelated=''
trap '[ -z "$unrelated" ] || kill "$unrelated" 2>/dev/null || true; rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export OWNED_PIDS="$work/owned-pids"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir "$db_work"
printf 'MemAvailable: 65536 kB\n' > "$work/meminfo"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
db_production_capture() { :; }; db_production_safe() { :; }
uci() { case "$*" in *dns_optimizer_protocols*|*dns_optimizer_bootstrap_protocols*) echo udp;; *) :;; esac; }
write_bootstrap_candidates() { printf 'first|First|1.1.1.1|default\nsecond|Second|9.9.9.9|default\n' > "$1"; }
write_main_candidates() { printf 'main|Main|8.8.8.8|default\n' > "$2"; }
candidate_primary_eligible_json() { echo true; }
db_native_start() { read -r actual rest < /proc/self/stat; printf '%s\n' "$actual" >> "$OWNED_PIDS"; }
db_measure_bootstrap() {
    db_native_command sh -c 'printf "%s\n" "$$" >> "$OWNED_PIDS"; exec sleep 20' || true
    echo '{"successCount":0,"totalQueries":1,"reliable":false}'
}
sleep 30 & unrelated=$!
for mode in marker signal; do
    rm -f "$db_cancel_file"; : > "$OWNED_PIDS"
    echo "cancellation mode: $mode"
    (
        trap 'db_cleanup' EXIT
        trap 'db_worker_signal' INT TERM HUP
        db_quick_benchmark
    ) & coordinator=$!
    tries=0
    while [ "$(wc -l < "$OWNED_PIDS" 2>/dev/null || echo 0)" -lt 4 ]; do
        sleep 0.1; tries=$((tries+1)); [ "$tries" -lt 50 ] || fail 'two native workers did not start'
    done
    started="$(date +%s)"; touch "$db_cancel_file"
    [ "$mode" != signal ] || kill -TERM "$coordinator"
    wait "$coordinator" 2>/dev/null || true
    [ "$(( $(date +%s)-started ))" -le 5 ] || fail 'cancellation unbounded'
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then fail "owned process $pid survived coordinator cleanup"; fi
    done < "$OWNED_PIDS"
    kill -0 "$unrelated" || fail 'unrelated process was signalled'
    [ ! -d "$db_work" ] || fail 'cancelled private directories retained'
    jq -e '.completion=="cancelled" and .partial and .individualComplete==false and .total==3 and .endpointCoverage.unmeasured==3' "$DB_STATUS" >/dev/null || fail 'cancelled coverage lost'
    mkdir "$db_work"
done
kill "$unrelated"; wait "$unrelated" 2>/dev/null || true; unrelated=''
echo 'PASS: real native worker/transport cancellation reaps owned children and preserves unrelated PID'
