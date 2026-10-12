#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$fixture_dir/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$fixture_dir/persist"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$fixture_dir/meminfo"
. "$repo/openwrt/podkop-dns-benchmark"
command -v db_wait_admission >/dev/null || fail 'graph admission check missing'
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
printf '{"state":"running","action":"recommend_verified","pid":0,"reportId":"wait-fixture"}\n' > "$DB_STATUS"
sha256sum "$DB_STATUS" > "$fixture_dir/status.before"

date() { case "$1" in +%s) printf '2\n';; *) command date "$@";; esac; }
sleep() { fail 'heavy graph admission must refuse immediately, not wait45s'; }
reset() { rm -f "$db_cancel_file" "$DB_DIR/waiting-memory.json"; printf 'MemAvailable: 40812 kB\n' > "$fixture_dir/meminfo"; db_deadline=0; db_probe_deadline=0; }
# Native ranking can proceed separately; graph clones must not wait or borrow
# the 148KiB missing from the unchanged 40MiB launch reserve.
reset
if db_wait_admission 40960; then fail '148KiB deficit admitted'; fi
[ "$db_child_error" = insufficient_memory ] || fail 'deficit reason missing'
jq -e '.waiting==false and .requiredKb==40960 and .availableKb==40812 and .waitLimitSeconds==0 and .waitedSeconds==0' "$DB_DIR/waiting-memory.json" >/dev/null || fail 'immediate refusal memory details missing'
db_status | jq -e '.state=="running" and (.memory.waiting//false)==false' >/dev/null || fail 'coordinator advertises nonexistent wait'
sha256sum -c "$fixture_dir/status.before" >/dev/null || fail 'status reader overwrote worker progress'
printf 'MemAvailable: 40960 kB\n' > "$fixture_dir/meminfo"
db_wait_admission 40960 || fail 'recovered 40MiB reserve not admitted'
[ ! -f "$DB_DIR/waiting-memory.json" ] || fail 'successful admission left stale progress'
reset; : > "$db_cancel_file"
if db_wait_admission 40960; then fail 'cancelled admission accepted'; fi
[ "$db_child_error" = cancelled ] || fail 'cancel did not stop admission'
[ ! -f "$DB_DIR/waiting-memory.json" ] || fail 'cancelled admission left progress'
reset; db_deadline=2
if db_wait_admission 40960; then fail 'expired operation admitted'; fi
[ "$db_child_error" = measurement_timeout ] || fail 'operation budget ignored'
reset; db_probe_deadline=2
if db_wait_admission 40960; then fail 'expired pair admitted'; fi
[ "$db_child_error" = pair_budget_exceeded ] || fail 'pair budget ignored'
reset; printf 'MemAvailable: 15000 kB\n' > "$fixture_dir/meminfo"
if db_wait_admission 40960; then fail 'pressure floor admitted'; fi
[ "$db_child_error" = memory_pressure ] || fail '16MiB pressure floor did not abort'
reset; printf 'MemTotal: 128000 kB\n' > "$fixture_dir/meminfo"
if db_wait_admission 40960; then fail 'unknown memory admitted'; fi
[ "$db_child_error" = memory_pressure ] || fail 'unknown memory did not fail closed'
[ ! -f "$DB_DIR/waiting-memory.json" ] || fail 'failed admission left stale progress'

echo 'PASS: unchanged40MiB immediate admission refusal/recovery, cancellation, deadlines and16MiB/unknown pressure floor'
