#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
. "$repo/openwrt/podkop-diagnostic-policy.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
PODKOP_DIAG_UPTIME_FILE="$work/uptime"
PODKOP_DIAG_MEMINFO_FILE="$work/meminfo"
PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
PODKOP_DIAG_MEMDOC_FILE="$work/memdoc"
printf 'THRESHOLD=20000\n' > "$work/memdoc"
printf 'MemAvailable: 40000 kB\n' > "$work/meminfo"
printf '100.0 0.0\n' > "$work/uptime"
diag_begin selection 60
db_light_policy=1
db_native_mode=1
db_native_command() { printf '%s\n' "$@" > "$work/args"; }
printf '159.0 0.0\n' > "$work/uptime"
db_native_dig udp 1.1.1.1 53 '' '' example.com
grep -Fxq '+timeout=1' "$work/args" || fail 'native query ignores last second budget'
printf '160.0 0.0\n' > "$work/uptime"
rm "$work/args"
if db_native_dig udp 1.1.1.1 53 '' '' example.com; then fail 'expired native request started'; fi
[ ! -e "$work/args" ] || fail 'deadline reached external DNS command'
printf '120.0 0.0\n' > "$work/uptime"
db_production_safe() { :; }
db_deadline=0; db_probe_deadline=0; db_cancel_file="$work/cancel"
printf 'MemAvailable: 28191 kB\n' > "$work/meminfo"
if db_runtime_safe; then fail 'native operation crossed watchdog reserve'; fi
[ "$db_child_error" = memory_pressure ] || fail 'memory refusal lost reason'
printf 'MemAvailable: 28192 kB\n' > "$work/meminfo"
db_runtime_safe || fail 'operation at safe reserve rejected'
echo 'PASS: real native DNS entrypoint respects remaining time and watchdog reserve'
