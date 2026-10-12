#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
production=''; tested=''
trap 'db_child_stop 2>/dev/null || true; [ -z "$production" ] || kill "$production" 2>/dev/null || true; [ -z "$tested" ] || kill "$tested" 2>/dev/null || true; rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$fixture_dir/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$fixture_dir/persist"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$fixture_dir/meminfo"
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
command -v db_resource_watch_start >/dev/null || fail 'scoped resource watchdog missing'
# Real commands may not benchmark a stopped production daemon. Library-only
# fixtures can omit it, but must not weaken the public command boundary.
(
  unset PODKOP_DNS_BENCHMARK_LIBRARY_ONLY
  pidof() { return 1; }
  if db_production_capture; then fail 'public benchmark accepted empty production baseline'; fi
  [ "$db_child_error" = production_stopped ] || fail 'empty production reason missing'
)
sleep 30 & production=$!
# Exact starttime plus parent ownership is required even for own processes.
db_resource_owned_file="$DB_DIR/forged-owned"
printf '%s invalid-old-starttime\n' "$production" > "$db_resource_owned_file"
read -r own_parent ignored < /proc/self/stat
db_resource_stop_registered "$own_parent"
kill -0 "$production" || fail 'forged registry starttime signalled production'
pidof() { printf '%s\n' "$production"; }
db_production_capture || fail 'could not capture production identity'
printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
db_resource_watch_start || fail 'watchdog startup failed'
sleep 30 & tested=$!
db_resource_register "$tested" || fail 'owned child identity registration failed'
printf 'MemAvailable: 15000 kB\n' > "$fixture_dir/meminfo"
attempts=0
while kill -0 "$tested" 2>/dev/null && [ "$attempts" -lt 5 ]; do sleep 1; attempts=$((attempts+1)); done
! kill -0 "$tested" 2>/dev/null || fail 'watchdog did not interrupt pressured owned child'
wait "$tested" 2>/dev/null || true; tested=''
kill -0 "$production" || fail 'watchdog signalled production process'
if db_runtime_safe; then fail 'pressure watchdog granted proof'; fi
[ "$db_child_error" = memory_pressure ] || fail 'pressure watchdog reason lost'
db_child_stop
printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
db_resource_watch_start || fail 'second watchdog startup failed'
sleep 30 & tested=$!
db_resource_register "$tested"
kill "$production"; wait "$production" 2>/dev/null || true
attempts=0
while kill -0 "$tested" 2>/dev/null && [ "$attempts" -lt 5 ]; do sleep 1; attempts=$((attempts+1)); done
! kill -0 "$tested" 2>/dev/null || fail 'watchdog continued after production disappearance'
wait "$tested" 2>/dev/null || true; tested=''; production=''
if db_runtime_safe; then fail 'missing production granted proof'; fi
[ "$db_child_error" = production_stopped ] || fail 'production identity failure reason lost'
db_child_stop
echo 'PASS: continuous pressure and production-PID/starttime watch, only registered owned children stopped, no proof on production loss'
