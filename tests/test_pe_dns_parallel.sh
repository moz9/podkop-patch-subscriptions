#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir -p "$db_work"
db_fingerprint() { echo stable; }; db_busy() { return 1; }; db_runtime_safe() { [ ! -f "$DB_DIR/cancel" ]; }
db_validate_pair() { :; }
configured_active_slot() { echo primary; }; read_configured_pair() { return 1; }
uci() { case "$*" in *dns_optimizer_protocols|*dns_optimizer_bootstrap_protocols) echo udp;; *) return 1;; esac; }
write_main_candidates() { printf '%s\n' 'first|First|1.1.1.1|unfiltered' 'second|Second|8.8.8.8|unfiltered' 'late|Late|9.9.9.10|unfiltered' > "$2"; }
write_bootstrap_candidates() { printf '%s\n' 'b1|First|1.1.1.1|unfiltered' 'b2|Second|8.8.8.8|unfiltered' > "$1"; }
(
    # Verify real admission policy; fake only host readings, not the decision.
    awk() { case "$*" in *MemAvailable*) echo "$memory_fixture";; */proc/loadavg*) [ "$load_fixture" = low ];; *) command awk "$@";; esac; }
    find() { printf 'worker1\nworker2\n'; }; grep() { echo 2; }
    memory_fixture=600000; load_fixture=low
    [ "$(db_parallel_limit)" = 1 ] || fail 'healthy router admitted concurrent runtime replicas'
    memory_fixture=310548
    [ "$(db_parallel_limit)" = 1 ] || fail '512MB router admitted concurrent replicas'
    memory_fixture=294911
    [ "$(db_parallel_limit)" = 1 ] || fail 'below calibrated two-worker reserve did not degrade'
    memory_fixture=294912
    [ "$(db_parallel_limit)" = 1 ] || fail 'old parallel boundary admitted concurrent replicas'
    memory_fixture=200000
    [ "$(db_parallel_limit)" = 1 ] || fail 'low memory did not reduce parallelism'
    memory_fixture=600000; load_fixture=high
    [ "$(db_parallel_limit)" = 1 ] || fail 'high CPU load did not reduce parallelism'
)
db_parallel_limit() { echo 2; }
db_check_pair() {
    printf '%s|%s|%s|%s|%s|%s\n' "$2" "$4" "$db_work" "$DB_DNS_PORT" "$DB_DIR" "$db_sample_cache_dir" >> "$work/runs"
    [ "$db_phase" != pairs ] || sleep 0.1
    score=50; [ "$2:$4" != late:8.8.8.8 ] || score=1
    if [ "${slow_confirmation:-false}:$db_phase:$2" = true:recheck:late ]; then score=200; fi
    if [ "${adversarial_confirmation:-false}" = true ]; then
        case "$db_phase:$2" in pairs:first) score=1;; pairs:second) score=2;; pairs:late) score=3;; recheck:first) score=100;; recheck:second) score=200;; recheck:late) score=4;; esac
    fi
    if [ "${comparison_only_fixture:-false}" = true ] && { [ "$2" = custom ] || [ "$4" = 9.9.9.9 ]; }; then score=0; fi
    db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" true "$5" | jq --argjson score "$score" '.httpsTested=true|.stats={reliable:true,averageMs:$score,scoreMs:$score}|.sectionResults=[]')"
    if [ "${cancel_fixture:-false}" = true ]; then : > "$work/state/cancel"; fi
}
db_action=recommend_full; db_deadline=$(( $(date +%s)+300 ))
wait() {
    wait_status=0; command wait "$@" || wait_status=$?
    printf '%s\n' "$1" >> "$work/waited-pids"
    return "$wait_status"
}
kill() {
    for kill_arg in "$@"; do :; done
    if grep -qx -- "$kill_arg" "$work/waited-pids" 2>/dev/null; then
        printf '%s\n' "$kill_arg" >> "$work/stale-kills"; return 1
    fi
    command kill "$@"
}
db_recommend || fail 'complete comparison failed'
[ ! -s "$work/stale-kills" ] || fail 'pool signalled a PID already reaped by wait'
unset -f wait kill
db_status | jq -e '.action=="recommend_full" and .recommendationMode=="full" and .selectionMode=="all_selected" and .exhaustiveSelected and .targetPairs==6 and .pairsTested==6 and .httpsTestedPairs==6 and .untestedHttpsPairs==0 and (.pairResults|length)==6 and .recommendation.id=="late" and .recommendation.bootstrapDnsServer=="8.8.8.8" and .confirmationChecks==2 and .parallelism==2' >/dev/null || fail 'late winner/all-selected coverage/rechecks missing'
[ "$(wc -l < "$work/runs")" = 8 ] || fail 'all six trials and top two repeats required'
[ "$(cut -d '|' -f3 "$work/runs" | sort -u | wc -l)" -ge 6 ] || fail 'parallel work directories reused'
[ "$(head -n 6 "$work/runs" | cut -d '|' -f4 | sort -u | wc -l)" = 2 ] || fail 'parallel workers share listener ports'
[ ! -s "$DB_PROOF" ] || fail 'recommendation granted apply proof'
[ "$(find "$db_work" -maxdepth 1 -type d -name 'pair-*' | wc -l)" = 0 ] || fail 'finished replicas accumulated in router tmpfs'
slow_confirmation=true; db_deadline=$(( $(date +%s)+300 ))
db_recommend || fail 'stable repeat comparison failed'
db_status | jq -e '.recommendation.id!="late" and .confirmationChecks==2 and (.pairResults|any(.id=="late" and .stableScoreMs==200))' >/dev/null || fail 'initial lucky sample outranked measured stable repeat'
slow_confirmation=false
(
    comparison_only_fixture=true
    write_main_candidates() { printf '%s\n' 'first|First|1.1.1.1|unfiltered' 'second|Second|8.8.8.8|unfiltered' 'late|Late|9.9.9.10|unfiltered' 'custom|Custom|208.67.222.222|custom' 'yandex|Yandex|77.88.8.8|unfiltered' > "$2"; }
    write_bootstrap_candidates() { printf '%s\n' 'b1|First|1.1.1.1|unfiltered' 'b2|Second|8.8.8.8|unfiltered' 'filtered|Filtered|9.9.9.9|security' > "$1"; }
    db_deadline=$(( $(date +%s)+300 ))
    db_recommend || fail 'comparison-only selected catalog failed'
    db_status | jq -e '.pairsTested==12 and .candidatesTotal==12 and .exhaustiveSelected and .recommendation.automaticEligible==true and .recommendation.id!="custom" and .recommendation.bootstrapDnsServer!="9.9.9.9" and (.pairResults|any(.id=="custom" and .automaticEligible==false)) and (.pairResults|all(.id!="yandex"))' >/dev/null || fail 'selected comparison-only pairs hidden, eligible policy or forbidden primary broken'
)
(
    adversarial_confirmation=true
    write_bootstrap_candidates() { printf 'b1|First|1.1.1.1|unfiltered\n' > "$1"; }
    db_deadline=$(( $(date +%s)+300 ))
    db_recommend || fail 'adaptive repeat comparison failed'
    db_status | jq -e '.pairsTested==3 and .confirmationChecks==3 and .recommendation.id=="late" and .recommendation.stableScoreMs==4' >/dev/null || fail 'unrechecked third candidate falsely lost to degraded leaders'
)
cancel_fixture=true; db_deadline=$(( $(date +%s)+300 ))
if db_recommend; then fail 'cancelled comparison selected winner'; fi
db_status | jq -e '.recommendation==null and .selectionComplete==false and .exhaustiveSelected==false and .error=="cancelled"' >/dev/null || fail 'partial cancellation claimed exhaustive winner'
[ -z "$db_pool_pids" ] || fail 'cancellation left pool workers'
db_parallel_limit() { echo 1; }
rm -f "$DB_DIR/cancel"; cancel_fixture=false
: > "$work/runs"; db_deadline=$(( $(date +%s)+300 ))
db_recommend || fail 'single-worker degraded mode failed'
db_status | jq -e '.parallelism==1 and .exhaustiveSelected and .pairsTested==6' >/dev/null || fail 'degraded mode shortened comparison'
[ "$(head -n 6 "$work/runs" | cut -d '|' -f4 | sort -u | wc -l)" = 1 ] || fail 'degraded mode used two port ranges'
rm -f "$DB_DIR/cancel"; cancel_fixture=false
db_deadline=$(( $(date +%s)-1 ))
if db_recommend; then fail 'expired comparison selected winner'; fi
db_status | jq -e '.recommendation==null and .exhaustiveSelected==false' >/dev/null || fail 'timeout selected partial winner'
# Exercise real per-worker signal cleanup with a live private child, not a
# stubbed stop routine. No production process or process group is targeted.
(
    (sleep 30 & printf '%s\n' "$!" > "$work/foreign-child"; wait) & guardian=$!
    tries=0
    while [ ! -s "$work/foreign-child" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries+1)); done
    foreign="$(cat "$work/foreign-child")"; db_pool_pids="$foreign"
    kill() { for target in "$@"; do :; done; [ "$target" != "$foreign" ] || { : > "$work/foreign-signalled"; return 1; }; command kill "$@"; }
    db_pool_stop
    db_child_pid="$foreign"; db_section_pids="$foreign"
    db_child_stop
    unset -f kill
    kill "$foreign" "$guardian" 2>/dev/null || true; wait "$guardian" 2>/dev/null || true
    [ ! -f "$work/foreign-signalled" ] || fail 'pool signalled a process not owned by coordinator'
)
(
    db_deadline=$(( $(date +%s)+300 ))
    db_check_pair() { sleep 30 & db_child_pid=$!; printf '%s\n' "$db_child_pid" > "$work/private-child"; wait "$db_child_pid" || true; }
    mkdir -p "$work/signal-worker"
    (db_pool_pair "$work/signal-worker" 0 udp first 1.1.1.1 8.8.8.8 udp) &
    db_pool_pids=$!
    tries=0
    while [ ! -s "$work/private-child" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries+1)); done
    [ -s "$work/private-child" ] || fail 'private child did not start'
    child="$(cat "$work/private-child")"
    db_pool_stop
    if kill -0 "$child" 2>/dev/null; then kill "$child"; fail 'cancel left private DNS child running'; fi
)
(
    # A complete 6-pair report is still below Linux's per-argument limit, but
    # confirmation details make it exceed 128 KiB during recheck publication.
    oversized="$(jq -nr '"x"*19000')"
    db_check_pair() {
        score=50; [ "$2" != late ] || score=1
        db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" true "$5" | jq -c --arg payload "$oversized" --argjson score "$score" '.stats={reliable:true,averageMs:$score,scoreMs:$score}|.sectionResults=[{section:"test",payload:$payload}]')"
    }
    db_deadline=$(( $(date +%s)+300 ))
    db_recommend || fail 'large report failed during recheck publication'
    db_status | jq -e '.state=="done" and .pairsTested==6 and .confirmationChecks>=2 and .recommendation!=null and (.pairResults|tojson|length)>131072' >/dev/null || fail 'large complete report was not published'
    [ ! -s "$DB_PROOF" ] || fail 'large recommendation granted apply proof'
)
echo 'PASS: all selected pairs, late winner, parallel isolation, repeats, cancellation'
