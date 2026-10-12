#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; old=''; replacement=''
trap '[ -z "$old" ] || kill "$old" 2>/dev/null || true; [ -z "$replacement" ] || kill "$replacement" 2>/dev/null || true; rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir "$db_work"
printf 'MemAvailable: 65536 kB\n' > "$work/meminfo"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
pidof() { echo capture >> "$work/captures"; cat "$work/current"; }
uci() { case "$*" in *dns_optimizer_protocols*|*dns_optimizer_bootstrap_protocols*) echo udp;; *) :;; esac; }
write_bootstrap_candidates() { printf 'boot1|Boot1|1.1.1.1|default\nboot2|Boot2|9.9.9.9|default\n' > "$1"; }
write_main_candidates() { printf 'main1|Main1|8.8.8.8|default\nmain2|Main2|8.8.4.4|default\n' > "$2"; }
candidate_primary_eligible_json() { echo true; }
# Exercise the real production capture/starttime checks without network traffic.
db_native_start() {
    [ -n "$db_production_file" ] || fail 'worker was not given coordinator baseline'
    db_production_capture && db_runtime_safe
}
db_query() { db_runtime_safe || return 1; case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|5';; esac; }
eval "$(sed -n '/^db_state() {/,/^}/p' "$repo/openwrt/podkop-dns-benchmark" | sed '1s/db_state/db_original_state/')"
db_state() {
    db_original_state "$@"
    if [ "$scenario" = replacement ] && [ "$1" = running ] && [ "$5" = 2 ]; then
        kill "$old"; wait "$old" 2>/dev/null || true
        echo "$replacement" > "$work/current"
    fi
}
for scenario in stable replacement; do
    sleep 60 & old=$!
    sleep 60 & replacement=$!
    echo "$old" > "$work/current"; : > "$work/captures"
    db_results='[]'; db_bootstrap_results='[]'; db_individual_complete=false; db_production_file=''; db_child_error=''
    rc=0; db_quick_benchmark || rc=$?
    [ -n "$db_production_file" ] || fail 'coordinator did not retain baseline'
    [ "$(wc -l < "$work/captures")" = 1 ] || fail 'worker recaptured production identity'
    [ "$(awk 'NR==1{print $1}' "$db_production_file")" = "$old" ] || fail 'baseline mutated to replacement process'
    [ -z "$(find "$DB_DIR" -name 'production-baseline.*' -print)" ] || fail 'baseline temporary file leaked'
    if [ "$scenario" = stable ]; then
        [ "$rc" = 0 ] || fail 'stable parallel operation failed'
        jq -e '.completion=="complete" and .completed==4' "$DB_STATUS" >/dev/null || fail 'stable coverage lost'
    else
        [ "$rc" != 0 ] || fail 'replacement production accepted'
        jq -e '.state=="error" and .completion=="partial" and .error=="production_stopped" and .completed==2 and .total==4 and .individualComplete==false' "$DB_STATUS" >/dev/null || fail 'replacement did not abort truthfully'
    fi
    kill "$old" "$replacement" 2>/dev/null || true
    wait "$old" 2>/dev/null || true; wait "$replacement" 2>/dev/null || true
    old=''; replacement=''
done
echo 'PASS: one immutable production baseline shared by native workers; replacement runtime aborts next batch'
