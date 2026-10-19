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
db_prepare; db_work="$work/probe"; mkdir -p "$db_work"
db_action=pair_test; db_deadline=$(( $(date +%s)+30 )); memory_fixture=65536
awk() { case "$*" in *MemAvailable*) echo "$memory_fixture";; *) command awk "$@";; esac; }
netstat() { :; }
db_make_pair_config() { : > "$work/cloned"; return 1; }
if db_child_start udp fixture 1.1.1.1 8.8.8.8 pair; then fail 'low memory admitted pair'; fi
[ ! -f "$work/cloned" ] || fail 'low memory cloned before admission'
dd if=/dev/zero of="$work/oversized.json" bs=1048576 count=17 2>/dev/null
memory_fixture=600000
if db_inline_runtime "$work/oversized.json" "$work/expanded.json"; then fail 'oversized runtime copied'; fi
[ ! -e "$work/expanded.json" ] || fail 'oversized runtime allocated private copy'
memory_fixture=600000
[ "$(db_parallel_limit)" = 1 ] || fail 'probe parallelism must be serial'
(
    memory_fixture=200000; checks=0
    db_make_pair_config() {
        printf '{}\n' > "$db_work/section-fixture.json"
        printf '{}\n' > "$4"
        jq -cn --arg config "$db_work/section-fixture.json" '[{config:$config,dnsPort:21010,proxyPort:21011}]' > "$db_work/sections.json"
    }
    db_resource_watch_start() { :; }
    db_check_config() { checks=$((checks+1)); memory_fixture=110000; return 0; }
    if db_child_start udp fixture 1.1.1.1 8.8.8.8 pair; then fail 'pressure after check admitted Go children'; fi
    [ "$checks" = 1 ] || fail 'second check ran below production reserve'
    [ -z "$db_child_pid$db_section_pids" ] || fail 'children spawned after pressure'
)
# The actual limiter must apply to manual tests too, not only recommendations.
db_deadline=$(( $(date +%s)+1 ))
if db_bounded_command sleep 3; then fail 'manual check escaped deadline'; fi
# No deadline runner means fail closed for commands without a native timeout.
command() { if [ "$*" = '-v timeout' ]; then return 1; fi; builtin command "$@"; }
db_deadline=$(( $(date +%s)+10 ))
if db_bounded_command sh -c ': > "$1"' sh "$work/unbounded"; then fail 'unbounded external command admitted'; fi
[ ! -f "$work/unbounded" ] || fail 'unbounded command ran'
unset -f command
if grep -E '(sing-box|"\$DB_BIN") run.*>.*\.log' "$repo/openwrt/podkop-dns-benchmark" >/dev/null; then fail 'long-lived probe logs grow without a bound'; fi
command -v db_resource_watch_start >/dev/null || fail 'continuous scoped watchdog absent'
db_infrastructure_error production_stopped || fail 'production loss treated as failed DNS candidate'
db_infrastructure_error deadline_runner_unavailable || fail 'missing deadline runner treated as DNS failure'
(
    sleep 30 & production=$!
    trap 'kill "$production" 2>/dev/null || true; db_child_stop' EXIT
    pidof() { printf '%s\n' "$production"; }
    printf 'MemAvailable: 600000 kB\n' > "$work/meminfo"
    export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
    # Use the actual runtime guard; host memory was mocked above.
    awk() { command awk "$@"; }
    db_deadline=$(( $(date +%s)+20 ))
    db_resource_watch_start || fail 'watchdog did not start'
    sleep 30 & private=$!; db_child_pid="$private"
    db_resource_register "$private" || fail 'private registration failed'
    printf 'MemAvailable: 50000 kB\n' > "$work/meminfo"
    tries=0
    while kill -0 "$private" 2>/dev/null && [ "$tries" -lt 5 ]; do sleep 1; tries=$((tries+1)); done
    kill -0 "$production" 2>/dev/null || fail 'watchdog killed production'
    if kill -0 "$private" 2>/dev/null; then fail 'watchdog retained probe under pressure'; fi
    read -r reason < "$db_resource_error_file"
    [ "$reason" = memory_pressure ] || fail 'watchdog lost pressure reason'
    wait "$private" 2>/dev/null || true
)
(
    sleep 30 & production=$!
    trap 'kill "$production" 2>/dev/null || true; db_child_stop' EXIT
    pidof() { printf '%s\n' "$production"; }
    printf 'MemAvailable: 600000 kB\n' > "$work/meminfo-check"
    export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo-check"
    awk() { command awk "$@"; }
    mkdir -p "$work/bin"
    printf '#!/bin/sh\nexec sleep 30\n' > "$work/bin/sing-box"
    chmod +x "$work/bin/sing-box"
    PATH="$work/bin:$PATH"; export PATH
    db_deadline=$(( $(date +%s)+20 ))
    db_resource_watch_start || fail 'check watchdog did not start'
    (sleep 1; printf 'MemAvailable: 50000 kB\n' > "$work/meminfo-check") & pressure=$!
    if db_check_config "$work/fixture.json"; then fail 'foreground check ignored pressure'; fi
    [ "$db_child_error" = memory_pressure ] || fail 'foreground check lost pressure error'
    kill -0 "$production" 2>/dev/null || fail 'foreground check stopped production'
    [ -z "$db_check_pid" ] || fail 'foreground check was not reaped'
    wait "$pressure"
)
(
    sleep 30 & production=$!
    trap 'kill "$production" 2>/dev/null || true; db_child_stop' EXIT
    pidof() { printf '%s\n' "$production"; }
    printf 'MemAvailable: 600000 kB\n' > "$work/meminfo-production"
    export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo-production"
    awk() { command awk "$@"; }
    db_deadline=$(( $(date +%s)+20 ))
    db_resource_watch_start || fail 'production watchdog did not start'
    sleep 30 & private=$!; db_child_pid="$private"
    db_resource_register "$private" || fail 'production-fixture registration failed'
    kill "$production"; wait "$production" 2>/dev/null || true
    tries=0
    while kill -0 "$private" 2>/dev/null && [ "$tries" -lt 5 ]; do sleep 1; tries=$((tries+1)); done
    if kill -0 "$private" 2>/dev/null; then fail 'probe survived disappearance of production'; fi
    read -r reason < "$db_resource_error_file"
    [ "$reason" = production_stopped ] || fail 'production change lost lifecycle error'
    wait "$private" 2>/dev/null || true
)
(
    sleep 30 & production=$!
    trap 'kill "$production" 2>/dev/null || true; db_child_stop' EXIT
    pidof() { printf '%s\n' "$production"; }
    printf 'MemAvailable: 600000 kB\n' > "$work/meminfo-replaced"
    export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo-replaced"
    awk() { command awk "$@"; }
    db_deadline=$(( $(date +%s)+20 ))
    db_resource_watch_start || fail 'identity watchdog did not start'
    sleep 30 & private=$!; db_child_pid="$private"
    db_resource_register "$private" || fail 'identity-fixture registration failed'
    start="$(db_pid_start "$production")"
    # Simulate PID reuse: the same numeric PID is no longer the bound instance.
    printf '%s %s\n' "$production" "$((start+1))" > "$db_production_file"
    tries=0
    while kill -0 "$private" 2>/dev/null && [ "$tries" -lt 5 ]; do sleep 1; tries=$((tries+1)); done
    if kill -0 "$private" 2>/dev/null; then fail 'probe survived replaced production identity'; fi
    kill -0 "$production" 2>/dev/null || fail 'watchdog killed replaced production PID'
    wait "$private" 2>/dev/null || true
)
echo 'PASS: PE pre-clone memory refusal, serial admission and all-mode deadlines'
