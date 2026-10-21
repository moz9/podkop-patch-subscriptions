#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'db_child_stop 2>/dev/null || true; rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$fixture_dir/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$fixture_dir/persist"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$fixture_dir/meminfo"
mkdir "$fixture_dir/bin"
cp "$repo/tests/fixtures/legacy-dns-resource-sing-box.sh" "$fixture_dir/bin/sing-box"
chmod +x "$fixture_dir/bin/sing-box"
export PATH="$fixture_dir/bin:$PATH"
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
printf '{}\n' > "$db_work/child.json"
command -v db_check_config >/dev/null || fail 'owned bounded config check missing'
# An unrelated process must survive both pressure abort and deadline abort.
sleep 30 & unrelated=$!
printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
export RESOURCE_CHECK_MODE=pressure
if db_check_config "$db_work/child.json"; then fail 'check ignored pressure immediately after validation'; fi
[ "$db_child_error" = memory_pressure ] || fail 'validation pressure reason lost'
[ -z "$db_check_pid" ] || fail 'pressure check PID not reaped'
kill -0 "$unrelated" || fail 'pressure cleanup signalled unrelated process'
printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
export RESOURCE_CHECK_MODE=hang
db_deadline=$(( $(date +%s)+1 )); began=$(date +%s)
if db_check_config "$db_work/child.json"; then fail 'hung check accepted'; fi
[ "$(( $(date +%s)-began ))" -le 4 ] || fail 'native check was not time bounded'
[ "$db_child_error" = measurement_timeout ] || fail 'hung check timeout reason lost'
[ -z "$db_check_pid" ] || fail 'timed-out check PID not reaped'
kill -0 "$unrelated" || fail 'timeout cleanup signalled unrelated process'
# A stale or forged validation PID must not signal another current child.
db_check_pid="$unrelated"; db_check_start=invalid-old-starttime
db_check_stop
kill -0 "$unrelated" || fail 'stale validation identity signalled unrelated child'
[ -z "$db_check_pid" ] || fail 'stale validation PID not cleared'
kill "$unrelated"; wait "$unrelated" 2>/dev/null || true
echo 'PASS: owned validation pressure/deadline abort, no external timeout required, no unrelated signal, check reaped'
