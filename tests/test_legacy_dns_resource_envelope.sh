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
export PODKOP_SECTION_ROOT="$fixture_dir/section-runtime"
export PODKOP_DNS_BENCHMARK_WORKERS_DIR="$fixture_dir/workers"
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
db_action=pair_test
# This library fixture intentionally has no production sing-box. Model that
# explicitly, independent of whether the host supplies Linux pidof (WSL) or
# not (Git Bash). Public capture remains fail-closed without pidof/production.
pidof() { return 1; }
netstat() { return 0; }
sleep() { :; }
db_make_config() { : > "$fixture_dir/cloned"; return 1; }
db_make_pair_config() { : > "$fixture_dir/cloned"; return 1; }
printf 'MemAvailable: 20000 kB\n' > "$fixture_dir/meminfo"
if db_child_start udp 1.1.1.1 8.8.8.8 udp individual; then fail 'unsafe individual launch accepted'; fi
[ ! -e "$fixture_dir/cloned" ] || fail 'individual clone ran before reserving child/transient memory'
[ "$db_child_error" = insufficient_memory ] || fail 'individual admission error not explicit'
mkdir "$PODKOP_SECTION_ROOT"; printf '{}\n' > "$PODKOP_SECTION_ROOT/worker.json"
printf 'MemAvailable: 35000 kB\n' > "$fixture_dir/meminfo"
if db_child_start udp 1.1.1.1 8.8.8.8 udp pair; then fail 'unsafe pair launch accepted'; fi
[ ! -e "$fixture_dir/cloned" ] || fail 'pair clone ran before unchanged40MiB admission'
[ "$db_child_error" = insufficient_memory ] || fail 'pair admission error not explicit'
mkdir -p "$DB_WORKERS_DIR/other"; printf '{}\n' > "$DB_WORKERS_DIR/other/worker.json"
printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
if db_child_start udp 1.1.1.1 8.8.8.8 udp pair; then fail 'legacy worker fanout accepted'; fi
[ ! -e "$fixture_dir/cloned" ] || fail 'multiworker clone ran before conservative legacy refusal'
[ "$db_child_error" = unsupported_section_runtime ] || fail 'legacy worker fanout reason missing'
# Public pair_test uses the same bounded-command path as recommendations.
timeout() { printf '%s\n' "$1" > "$fixture_dir/timeout"; shift; "$@"; }
db_deadline=$(( $(date +%s)+20 ))
db_bounded_command true || fail 'bounded normal pair command failed'
[ -s "$fixture_dir/timeout" ] || fail 'pair_test skipped command time bound'
[ "$(cat "$fixture_dir/timeout")" -le 20 ] || fail 'pair command exceeded operation budget'
# After the one worker consumes memory, admit the front separately rather
# than treating the 16MiB runtime stop floor as another child launch budget.
(
  trap 'db_child_stop' EXIT
  db_deadline=0
  mkdir "$fixture_dir/bin"
  cp "$repo/tests/fixtures/legacy-dns-resource-sing-box.sh" "$fixture_dir/bin/sing-box"
  chmod +x "$fixture_dir/bin/sing-box"
  PATH="$fixture_dir/bin:$PATH"; export PATH RESOURCE_CHECK_MODE=hang
  db_worker_configs() { printf '%s\n' "$PODKOP_SECTION_ROOT/worker.json"; }
  db_resource_watch_start() { :; }
  db_check_config() { :; }
  db_resource_register() { printf 'MemAvailable: 30000 kB\n' > "$fixture_dir/meminfo"; }
  db_make_pair_config() {
    printf '{}\n' > "$4"; printf '{}\n' > "$db_work/section-main.json"
    jq -n --arg config "$db_work/section-main.json" '[{section:"main",config:$config,dnsPort:19602,proxyPort:19603}]' > "$db_work/sections.json"
  }
  dig() { echo 93.184.216.34; }
  printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
  if db_child_start udp 1.1.1.1 8.8.8.8 udp pair; then fail 'front launched below its own reserve after worker'; fi
  [ "$db_child_error" = insufficient_memory ] || fail 'front per-child admission reason missing'
  [ -z "$db_child_pid" ] || fail 'front borrowed production reserve'
)
echo 'PASS: preclone single/pair admission, unchanged40MiB pair reserve, no legacy worker fanout, normal pair command timeout'
