#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
. "$repo/openwrt/podkop-diagnostic-policy.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
PODKOP_DIAG_MEMDOC_FILE="$work/no-watchdog"
db_light_policy=1; db_native_mode=1
db_deadline=0; db_probe_deadline=0; db_cancel_file="$work/cancel"
db_production_safe() { :; }
now() { awk '{print $1}' /proc/uptime; }
assert_stopped() {
    elapsed="$(awk -v start="$1" '{print $1-start}' /proc/uptime)"
    awk -v elapsed="$elapsed" 'BEGIN {exit !(elapsed<2)}' || fail "owned native command cleanup exceeded 2s: $elapsed"
    child="$(cat "$work/child")"
    [ ! -e "/proc/$child" ] || fail 'native command survived cleanup'
}
diag_begin pair 1
started="$(now)"
if db_native_command sh -c 'echo $$ > "$1"; exec sleep 10' fixture "$work/child"; then fail 'timed-out child reported success'; fi
assert_stopped "$started"
diag_begin selection 10
(sleep 0.2; : > "$work/cancel") & cancel_writer=$!
started="$(now)"
if db_native_command sh -c 'echo $$ > "$1"; exec sleep 10' fixture "$work/child"; then fail 'cancelled child reported success'; fi
wait "$cancel_writer"
assert_stopped "$started"
echo 'PASS: actual owned native processes stop under 2s on deadline/cancel without network or router writes'
