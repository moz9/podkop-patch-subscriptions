#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TMPDIR="$work/tmp"; mkdir "$TMPDIR"; export TMPDIR
eval "$(sed '/^case "${1:-}" in/,$d' "$repo/openwrt/podkop-dns-optimizer")"
fail() { echo "FAIL: $*" >&2; exit 1; }
PODKOP_DNS_OPTIMIZER_MEMINFO_FILE="$work/meminfo"
STATE_DIR="$work/state"; STATUS_FILE="$STATE_DIR/status.json"; LOCK_DIR="$STATE_DIR/lock"
PERSIST_DIR="$work/persist"; LAST_BENCHMARK_FILE="$PERSIST_DIR/last-benchmark.json"
write_main_candidates() { printf 'cloudflare|Cloudflare|1.1.1.1|unfiltered\n' > "$2"; }
write_bootstrap_candidates() { printf 'google_1|Google|8.8.8.8|unfiltered\n' > "$1"; }
uci() {
    printf '%s\n' "$*" >> "$work/uci.calls"
    case "$*" in
        *'show podkop') echo "podkop.main.connection_type='proxy'";;
        *podkop.main.connection_type) echo proxy;;
        *podkop.main.community_lists) echo youtube;;
        *) return 1;;
    esac
}
run_with_timeout() { shift; "$@"; }
dig() {
    local domain="$2"
    printf '%s|%s\n' "$1" "$domain" >> "$work/queries"
    if [ "$domain" = "${mandatory_fail:-none}" ] || [ "$1" = "${dead_resolver:-none}" ]; then
        echo ';; status: SERVFAIL'; return 0
    fi
    case "$domain" in *.invalid)
        if [ "${bad_nx:-0}" = 1 ]; then echo ';; status: NOERROR'; else echo ';; status: NXDOMAIN'; fi;;
        *) echo ';; status: NOERROR'; printf '%s 60 IN A 93.184.216.34\n' "$domain";; esac
    echo ';; Query time: 5 msec'
    if [ "${drop_after:-0}" -gt 0 ] && [ "$(wc -l < "$work/queries")" -eq "$drop_after" ]; then
        printf 'MemAvailable: 16000 kB\n' > "$work/meminfo"
    fi
}
sleep() {
    [ "$1" = 1 ] || fail 'fractional/unbounded memory sleep'
    echo 1 >> "$work/sleeps"
    if [ "${resume_memory:-0}" = 1 ]; then printf 'MemAvailable: 40000 kB\n' > "$work/meminfo"; fi
    if [ "${resume_memory:-0}" = 2 ]; then
        if [ "$(wc -l < "$work/sleeps")" -eq 1 ]; then printf 'MemAvailable: 28000 kB\n' > "$work/meminfo"
        else printf 'MemAvailable: 40000 kB\n' > "$work/meminfo"; fi
    fi
}
run_case() {
    : > "$work/queries"; : > "$work/uci.calls"; : > "$work/sleeps"
    if (run_benchmark udp "$1"); then rc=0; else rc=$?; fi
    [ -s "$STATUS_FILE" ] || fail 'missing benchmark status'
    ! grep -Eq '(^| )(set|commit|add|delete)( |$)' "$work/uci.calls" || fail 'benchmark mutated UCI'
}
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
run_case auto
jq -e '.state=="success" and .benchmarkMode=="economy" and .requestedMode=="auto" and .parallelism==1 and .diagnosticsSkipped==true and .benchmarkScope=="dns-only" and .optionalProbeCoverage=="skipped" and .memory.startAvailableKiB==80000 and .memory.minAvailableKiB==80000 and .memory.waitCount==0 and (.results|all(.diagnosticsSkipped==true and .advisoryPassed==0 and .advisoryStable==0 and .advisoryScore==0 and .communityScore==0 and .communityTested==0 and (.communityResults|all(.tested==false and .passed==null))))' "$STATUS_FILE" >/dev/null || fail 'auto economy/memory truthful diagnostics metadata absent'
for domain in play.googleapis.com chatgpt.com api.openai.com; do
    [ "$(grep -c "|$domain$" "$work/queries")" -eq 2 ] || fail 'mandatory two rounds missing'
done
grep -q '|podkop-dns-test.invalid$' "$work/queries" || fail 'NXDOMAIN skipped'
[ "$(grep -c '^@8.8.8.8|' "$work/queries")" -eq 9 ] || fail 'bootstrap eight queries plus warmup changed'
! grep -Eq '\|(auth.openai.com|chat.openai.com|youtube.com|googlevideo.com)$' "$work/queries" || fail 'optional diagnostics not omitted'
printf 'MemAvailable: 150000 kB\n' > "$work/meminfo"
run_case auto
jq -e '.benchmarkMode=="full" and .diagnosticsSkipped==false' "$STATUS_FILE" >/dev/null || fail 'auto high memory not full'
grep -q '|youtube.com$' "$work/queries" || fail 'full diagnostics omitted'
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
run_case full
jq -e '.benchmarkMode=="full" and .requestedMode=="full"' "$STATUS_FILE" >/dev/null || fail 'explicit full ignored'
for mandatory_fail in play.googleapis.com chatgpt.com api.openai.com; do
    run_case economy
    jq -e '.state=="error" and .recommendation==null and .secondaryRecommendation==null and (.results|all(.reliable==false and .universalEligible==false))' "$STATUS_FILE" >/dev/null || fail 'economy relaxed mandatory failure'
done
mandatory_fail=none; bad_nx=1
run_case economy
jq -e '.state=="error" and .recommendation==null and (.results|all(.error=="nxdomain_check_failed" and .nxdomainOk==false))' "$STATUS_FILE" >/dev/null || fail 'economy relaxed NXDOMAIN safety gate'
bad_nx=0; dead_resolver=@1.1.1.1
run_case economy
[ "$(grep -c '^@1.1.1.1|play.googleapis.com$' "$work/queries")" -eq 2 ] || fail 'economy failed DNS skipped mandatory rounds'
[ "$(grep -c '^@1.1.1.1|api.openai.com$' "$work/queries")" -eq 2 ] || fail 'economy failed DNS omitted later mandatory domains'
dead_resolver=@8.8.8.8
run_case economy
[ "$(grep -c '^@8.8.8.8|' "$work/queries")" -eq 9 ] || fail 'economy failed bootstrap skipped eight queries'
dead_resolver=none; drop_after=10; resume_memory=1
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
run_case economy
jq -e '.state=="success" and .memory.minAvailableKiB==16000 and .memory.waitCount==1 and .memory.waitSeconds==1' "$STATUS_FILE" >/dev/null || fail 'memory drop did not pause/resume or propagate subshell metrics'
[ "$(wc -l < "$work/sleeps")" -eq 1 ] || fail 'memory wait budget'
resume_memory=2
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
run_case economy
jq -e '.state=="success" and .memory.waitCount==1 and .memory.waitSeconds==2' "$STATUS_FILE" >/dev/null || fail 'memory hysteresis resumed below 32MiB'
[ "$(wc -l < "$work/sleeps")" -eq 2 ] || fail 'memory hysteresis wait budget'
resume_memory=0; drop_after=10
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
run_case economy
jq -e '.state=="error" and .message=="resource_wait_timeout" and .recommendation==null and .secondaryRecommendation==null and .memory.waitSeconds==45' "$STATUS_FILE" >/dev/null || fail 'mid-candidate resource failure swallowed as network error'
[ "$(wc -l < "$work/queries")" -eq 10 ] || fail 'queries continued after memory timeout'
[ "$rc" -ne 0 ] || fail 'timeout returned success'
drop_after=0
printf 'MemTotal: 128000 kB\n' > "$work/meminfo"
run_case auto
jq -e '.benchmarkMode=="economy" and .state=="error" and .message=="resource_wait_timeout" and .memory.startAvailableKiB==null' "$STATUS_FILE" >/dev/null || fail 'unknown memory not fail-safe'
[ ! -s "$work/queries" ] || fail 'unknown memory ran DNS'
run_case invalid
jq -e '.state=="error" and .message=="invalid_resource_mode"' "$STATUS_FILE" >/dev/null || fail 'invalid mode accepted'
if (run_benchmark unsupported auto); then fail 'invalid protocols accepted'; fi
jq -e '.message=="invalid_protocol"' "$STATUS_FILE" >/dev/null || fail 'invalid protocol reason lost'
[ -z "$(ls -A "$TMPDIR")" ] || fail 'benchmark leaked temporary files, including on invalid protocols'
# The bootstrap hostname lookup uses dig directly, not run_dns_query. Resource
# failure there must abort its pipeline and the whole benchmark without a winner.
write_main_candidates() { printf 'cloudflare|Cloudflare|dns.example/dns-query|unfiltered\n' > "$2"; }
drop_after=9
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
run_case economy
jq -e '.state=="error" and .message=="resource_wait_timeout" and .recommendation==null' "$STATUS_FILE" >/dev/null || fail 'hostname lookup resource failure swallowed'
[ "$(wc -l < "$work/queries")" -eq 9 ] || fail 'hostname lookup ran under memory pressure'
# Deliver TERM to a separate real shell after the benchmark owns its traps.
# This does not signal the test runner and needs no timing-dependent sleep.
printf 'MemAvailable: 80000 kB\n' > "$work/meminfo"
: > "$work/queries"
if sh -c '
    work="$1"; repo="$2"
    eval "$(sed '\''/^case "${1:-}" in/,$d'\'' "$repo/openwrt/podkop-dns-optimizer")"
    STATE_DIR="$work/state"; STATUS_FILE="$STATE_DIR/status.json"; LOCK_DIR="$STATE_DIR/lock"
    PODKOP_DNS_OPTIMIZER_MEMINFO_FILE="$work/meminfo"
    write_main_candidates() { kill -TERM "$$"; }
    run_benchmark udp economy
' sh "$work" "$repo"; then fail 'cancelled benchmark returned success'; fi
jq -e '.state=="error" and .message=="benchmark_cancelled" and .recommendation==null and .secondaryRecommendation==null' "$STATUS_FILE" >/dev/null || fail 'cancelled benchmark recommended a winner'
[ ! -s "$work/queries" ] || fail 'cancelled benchmark continued probes'
[ -z "$(ls -A "$TMPDIR")" ] || fail 'cancelled benchmark leaked temporary files'
# Real TERM during the nested guard. The test clock accelerates sleep but the
# production guard still requests only integer1 and remains bounded45 iterations.
# POSIX shells may defer the parent trap until its substitution completes; do
# not promise instant cancellation, only a bounded exit with no orphan/winner.
printf 'MemAvailable: 16000 kB\n' > "$work/meminfo"
sh -c '
    work="$1"; repo="$2"
    eval "$(sed '\''/^case "${1:-}" in/,$d'\'' "$repo/openwrt/podkop-dns-optimizer")"
    STATE_DIR="$work/state"; STATUS_FILE="$STATE_DIR/status.json"; LOCK_DIR="$STATE_DIR/lock"
    PODKOP_DNS_OPTIMIZER_MEMINFO_FILE="$work/meminfo"
    write_main_candidates() { printf "cloudflare|Cloudflare|1.1.1.1|unfiltered\n" > "$2"; }
    write_bootstrap_candidates() { printf "google_1|Google|8.8.8.8|unfiltered\n" > "$1"; }
    uci() { return 1; }
    dig() { echo unexpected >> "$work/queries"; return 1; }
    sleep() { [ "$1" = 1 ] || exit 2; : > "$work/entered"; command sleep 0.03; }
    run_benchmark udp economy
' sh "$work" "$repo" &
cancel_pid=$!
attempts=0
while [ ! -e "$work/entered" ] && [ "$attempts" -lt 200 ]; do command sleep 0.01; attempts=$((attempts + 1)); done
[ -e "$work/entered" ] || fail 'nested cancellation fixture did not enter guard'
kill -TERM "$cancel_pid"
if wait "$cancel_pid"; then fail 'nested cancellation returned success'; fi
jq -e '.state=="error" and .message=="benchmark_cancelled" and .recommendation==null and .memory.waitSeconds<=45' "$STATUS_FILE" >/dev/null || fail 'nested cancellation lacks bounded terminal state'
cp "$STATUS_FILE" "$work/cancelled-status"
command sleep 0.15
cmp "$STATUS_FILE" "$work/cancelled-status" >/dev/null || fail 'orphaned guard overwrote terminal cancellation'
[ ! -s "$work/queries" ] || fail 'nested cancelled benchmark ran DNS'
[ -z "$(ls -A "$TMPDIR")" ] || fail 'nested cancellation leaked temporary files'
# Simulate the worker completing while the reader is checking its stale PID.
printf '%s\n' '{"state":"running","pid":9876,"updatedAt":"old","message":"working"}' > "$STATUS_FILE"
mkdir -p "$LOCK_DIR"
pid_alive() {
    printf '%s\n' '{"state":"success","pid":9876,"updatedAt":"new","message":"benchmark_complete","recommendation":{"id":"cloudflare"}}' > "$STATUS_FILE"
    return 1
}
show_status > "$work/view"
jq -e '.state=="success" and .recommendation.id=="cloudflare"' "$work/view" >/dev/null || fail 'status reader overwrote concurrent terminal result'
jq -e '.state=="success"' "$STATUS_FILE" >/dev/null || fail 'status reader mutated terminal file'
[ -d "$LOCK_DIR" ] || fail 'status reader removed worker-owned lock'
printf '%s\n' '{"state":"running","pid":9876,"updatedAt":"old","message":"working","recommendation":{"id":"stale"}}' > "$STATUS_FILE"
pid_alive() { return 1; }
show_status > "$work/view"
jq -e '.state=="error" and .message=="worker_stopped" and .recommendation==null and .secondaryRecommendation==null' "$work/view" >/dev/null || fail 'dead worker still recommends'
jq -e '.state=="running"' "$STATUS_FILE" >/dev/null || fail 'status reader recovery must be read-only'
[ -d "$LOCK_DIR" ] || fail 'status reader removed worker-owned lock'
echo 'PASS: legacy bounded economy, mandatory probes, full parity, truthful diagnostics, low/unknown-memory pause/resume/timeout, no UCI mutation, race-safe read-only status'
