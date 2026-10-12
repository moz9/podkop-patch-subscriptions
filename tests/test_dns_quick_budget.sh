#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir "$db_work"
db_production_capture() { :; }; db_production_safe() { :; }
db_child_start() { fail 'native queue launched engine'; }
db_child_admission() { fail 'native queue requested engine admission'; }
db_fingerprint() { fail 'native queue fingerprints whole graph'; }
db_prepare_runtime_cache() { fail 'native queue clones graph'; }
uci() { case "$*" in *dns_optimizer_protocols*|*dns_optimizer_bootstrap_protocols*) echo udp;; *bootstrap_dns_server*) echo 1.1.1.1;; *) :;; esac; }
write_bootstrap_candidates() { printf 'boot|Boot|1.1.1.1|default\n' > "$1"; }
write_main_candidates() { i=0; : > "$2"; while [ "$i" -lt 44 ]; do i=$((i+1)); printf 'id%s|Provider|8.8.8.8|default\n' "$i" >> "$2"; done; }
candidate_primary_eligible_json() { echo true; }
db_child_stop() { :; }
date() { if [ "$*" = +%s ]; then cat "$work/clock"; else command date "$@"; fi; }
db_native_start() {
    case "$scenario" in
      sequential) printf '%s\n' "$(( $(cat "$work/clock")+2 ))" > "$work/clock";;
      parallel) if mkdir "$work/slot1" 2>/dev/null; then slot=1; elif mkdir "$work/slot2" 2>/dev/null; then slot=2; touch "$work/two"; else fail 'more than two workers'; fi; sleep 0.02; rmdir "$work/slot$slot";;
      endpoint_timeout) printf '%s\n' "$(( $(cat "$work/clock")+21 ))" > "$work/clock";;
      pressure) printf 'MemAvailable: 8000 kB\n' > "$work/meminfo";;
      cancelled) touch "$db_cancel_file";;
    esac
    db_native_mode=1
}
db_query() { db_runtime_safe || return 1; case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|5';; esac; }
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
run_queue() {
    printf '100\n' > "$work/clock"; rm -f "$db_cancel_file"
    db_deadline=0; db_probe_deadline=0; db_child_error=''; db_pool_pids=''
    db_results='[]'; db_bootstrap_results='[]'; db_pair_results='[]'; db_pair_json=null; db_recommendation=null; db_individual_complete=false
    printf stale > "$DB_PROOF"
    db_quick_benchmark
}
printf 'MemAvailable: 39936 kB\n' > "$work/meminfo"; scenario=sequential
run_queue || fail 'full sequential queue failed'
jq -e '.completion=="complete" and .state=="done" and .completed==45 and .total==45 and .elapsedSeconds==90 and .partial==false and .individualComplete and .endpointCoverage.unmeasured==0 and .parallelism==1 and .httpsTested==false and .recommendation==null' "$DB_STATUS" >/dev/null || fail 'complete low memory coverage missing'
[ ! -e "$DB_PROOF" ] || fail 'endpoint queue retained apply proof'
printf 'MemAvailable: 65536 kB\n' > "$work/meminfo"; scenario=parallel
run_queue || fail 'parallel queue failed'
[ -e "$work/two" ] || fail 'two native workers not exercised'
jq -e '.completion=="complete" and .completed==45 and .maxParallelism==2 and .parallelism==2 and (.results|length)==44' "$DB_STATUS" >/dev/null || fail 'parallel rows lost'
[ -z "$(find "$db_work" -type d -name 'endpoint-*' -print)" ] || fail 'completed worker directories accumulated'
printf 'MemAvailable: 39936 kB\n' > "$work/meminfo"; scenario=pressure
if run_queue; then fail 'resource abort became success'; fi
jq -e '.state=="error" and .completion=="resource_abort" and .partial and .individualComplete==false and .completed==0 and .endpointCoverage.unmeasured==45' "$DB_STATUS" >/dev/null || fail 'resource abort coverage false'
printf 'MemAvailable: 39936 kB\n' > "$work/meminfo"; scenario=cancelled
if run_queue; then fail 'cancel became success'; fi
jq -e '.completion=="cancelled" and .partial and .individualComplete==false' "$DB_STATUS" >/dev/null || fail 'cancel state missing'
# A timed-out endpoint is a completed failed attempt, never reliable DNS.
write_main_candidates() { printf 'main|Main|8.8.8.8|default\n' > "$2"; }
printf 'MemAvailable: 39936 kB\n' > "$work/meminfo"; scenario=endpoint_timeout
run_queue || fail 'individual timeout aborted full queue'
jq -e '.completion=="complete" and .completed==2 and .total==2 and (.results|all(.error=="endpoint_timeout" and .reliable==false)) and (.bootstrapResults|all(.error=="endpoint_timeout" and .reliable==false))' "$DB_STATUS" >/dev/null || fail 'endpoint timeout became reliability or unmeasured coverage'
rm -f "$db_cancel_file"; printf 'unknown\n' > "$work/meminfo"
[ "$(db_endpoint_parallel_limit)" = 1 ] || fail 'unknown memory did not use conservative concurrency'
if db_runtime_safe; then fail 'unknown memory admitted'; fi
[ -z "$db_pool_pids" ] || fail 'reaped worker ownership retained'
# Cancellation in the final-publication window must not turn the previous
# running progress snapshot into a completed report.
eval "$(sed -n '/^db_state() {/,/^}/p' "$repo/openwrt/podkop-dns-benchmark" | sed '1s/db_state/db_original_state/')"
db_state() {
    [ "$1" != done ] || touch "$db_cancel_file"
    db_original_state "$@"
}
printf 'MemAvailable: 39936 kB\n' > "$work/meminfo"; scenario=sequential
if run_queue; then fail 'final-publication cancellation returned success'; fi
jq -e '.state=="cancelled" and .completion=="cancelled" and .partial and .individualComplete==false and .completed==2 and .total==2' "$DB_STATUS" >/dev/null || fail 'final-publication cancellation fabricated completion'
# Read-side recovery must revoke stale complete flags too.
jq '.state="done"|.completion="complete"|.partial=false|.individualComplete=true' "$DB_STATUS" > "$work/stale"; mv "$work/stale" "$DB_STATUS"
db_status | jq -e '.state=="cancelled" and .completion=="cancelled" and .partial and .individualComplete==false' >/dev/null || fail 'read-side cancellation retained complete flags'
rm -f "$db_cancel_file"
jq '.state="running"|.pid=999999|.completion="complete"|.partial=false|.individualComplete=true' "$DB_STATUS" > "$work/stale"; mv "$work/stale" "$DB_STATUS"
pid_alive() { return 1; }
db_status | jq -e '.state=="error" and .error=="worker_stopped" and .completion=="partial" and .partial and .individualComplete==false' >/dev/null || fail 'stopped worker retained complete flags'
echo 'PASS: complete native endpoint queue, 1/2 workers, no 60s truncation, explicit resource/cancel coverage'
