#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v db_quick_benchmark >/dev/null || fail 'quick budget boundary absent'
db_prepare; db_work="$work/run"; mkdir "$db_work"
db_action=benchmark; db_resource_error_file=''; db_resource_watch_pid=''; db_section_pids=''
db_production_capture() { :; }; db_production_safe() { :; }
db_child_start() { fail 'quick test launched engine'; }
db_child_admission() { fail 'quick test requested engine admission'; }
db_fingerprint() { fail 'quick test fingerprints whole graph'; }
db_prepare_runtime_cache() { fail 'quick test clones graph'; }
uci() { case "$*" in *dns_optimizer_protocols*) echo udp;; *dns_optimizer_bootstrap_protocols*) echo udp;; *bootstrap_dns_server*) echo 1.1.1.1;; *) :;; esac; }
write_bootstrap_candidates() { printf 'boot|Boot|1.1.1.1|default\n' > "$1"; }
write_main_candidates() { printf 'first|First|8.8.8.8|default\nsecond|Second|9.9.9.9|default\nthird|Third|1.0.0.1|default\n' > "$2"; }
candidate_primary_eligible_json() { echo true; }
db_child_stop() { :; }
date() { if [ "$*" = +%s ]; then cat "$work/clock"; else command date "$@"; fi; }
export PODKOP_DIAG_UPTIME_FILE="$work/clock" PODKOP_DIAG_MEMDOC_FILE="$work/no-watchdog"
db_native_start() {
    db_native_mode=1
    printf '%s\n' "$(( $(cat "$work/clock") + step ))" > "$work/clock"
}
db_query() { db_runtime_safe || return 1; case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|5';; esac; }
printf 'MemAvailable: 65536 kB\n' > "$work/meminfo"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
run_quick() {
    printf '100\n' > "$work/clock"
    db_deadline=0; db_probe_deadline=0; db_child_error=''
    db_results='[]'; db_bootstrap_results='[]'; db_pair_results='[]'; db_pair_json=null; db_recommendation=null; db_individual_complete=false
    printf stale > "$DB_PROOF"
    db_quick_benchmark
}
step=20
db_state running benchmark measuring 0 0 4 ''
jq -e '.budgetSeconds==60 and .measurementProfile=="native_endpoints" and .httpsTested==false' "$DB_STATUS" >/dev/null || fail 'running quick status reports wrong budget/scope'
run_quick || fail 'budget exhaustion falsely failed operation'
[ "$db_deadline" = 160 ] || fail 'actual deadline differs from 60s budget'
jq -e '.state=="done" and .action=="benchmark" and .phase=="quick_endpoints" and .budgetSeconds==60 and .elapsedSeconds==60 and .budgetExhausted and .partial and .individualComplete==false and .selectionComplete==false and .recommendation==null and .pairResult==null and .httpsTested==false and .fullVerificationComplete==false and .completed<.total and (.results|any(.successCount==2 and .httpsTested==false))' "$DB_STATUS" >/dev/null || fail 'partial rows or truthful scope/budget missing'
[ ! -e "$DB_PROOF" ] || fail 'quick result retained apply proof'
step=5
run_quick || fail 'complete quick measurement failed'
jq -e '.state=="done" and .budgetSeconds==60 and .budgetExhausted==false and .partial==false and .individualComplete and .completed==.total and .recommendation==null and .httpsTested==false' "$DB_STATUS" >/dev/null || fail 'complete DNS-only status false'
step=15
run_quick || fail 'expiry inside final candidate falsely failed operation'
jq -e '.budgetExhausted and .partial and .individualComplete==false and .completed==.total and .recommendation==null' "$DB_STATUS" >/dev/null || fail 'final candidate expiry claimed full completion'
# The guard may pass at second59 and the following explicit deadline check
# observe second60. Exercise that between-endpoints race independently.
db_runtime_safe() {
    if [ "$(jq -r '.completed//0' "$DB_STATUS")" -ge 1 ] && [ ! -e "$work/raced" ]; then
        printf '160\n' > "$work/clock"; touch "$work/raced"; return 0
    fi
    [ "$(date +%s)" -lt "$db_deadline" ] || { db_child_error=measurement_timeout; return 1; }
}
printf '{}' > "$DB_STATUS"; step=5
run_quick || fail 'between-endpoint expiry lost partial operation'
jq -e '.budgetExhausted and .partial and .completed==1 and (.bootstrapResults|length>0)' "$DB_STATUS" >/dev/null || fail 'between-endpoint partial measurements lost'
db_runtime_safe() { db_child_error=memory_pressure; return 1; }
if run_quick; then fail 'memory pressure became budget partial-success'; fi
jq -e '.state=="error" and .error=="memory_pressure"' "$DB_STATUS" >/dev/null || fail 'pressure diagnostic lost'
# Wall clock adjustments must not make the reported duration negative.
export PODKOP_DIAG_UPTIME_FILE="$work/uptime"
printf '100.0 0.0\n' > "$work/uptime"
db_benchmark() {
    printf '90\n' > "$work/clock"
    printf '107.0 0.0\n' > "$work/uptime"
    printf '{"completed":1,"total":1}\n' > "$DB_STATUS"
}
run_quick || fail 'wall-clock adjustment aborted completed monotonic measurement'
jq -e '.elapsedSeconds==7 and .partial==false' "$DB_STATUS" >/dev/null || fail 'reported duration follows wall clock instead of monotonic time'
echo 'PASS: 60s native-only quick DNS, honest partial rows, monotonic duration, no apply proof and pressure diagnostics'
