#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"; production=''
trap 'db_child_stop 2>/dev/null || true; if [ -n "$production" ]; then kill "$production" 2>/dev/null || true; wait "$production" 2>/dev/null || true; fi; rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$fixture_dir/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$fixture_dir/persist"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$fixture_dir/meminfo"
export PODKOP_SECTION_ROOT="$fixture_dir/native" PODKOP_DNS_BENCHMARK_WORKERS_DIR="$fixture_dir/workers"
export GOGC=100 GOMEMLIMIT=800MiB OOM_TRACE="$fixture_dir/trace"
mkdir "$fixture_dir/bin"
cp "$repo/tests/fixtures/legacy-dns-oom-sing-box.sh" "$fixture_dir/bin/sing-box"
chmod +x "$fixture_dir/bin/sing-box"
PATH="$fixture_dir/bin:$PATH"; export PATH
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
read -r parent_score < /proc/self/oom_score_adj
sleep 30 & production=$!
read -r production_score < "/proc/$production/oom_score_adj"
pidof() { printf '%s\n' "$production"; }
netstat() { :; }
dig() { echo 93.184.216.34; }
db_make_pair_config() {
  printf '{}\n' > "$4"; printf '{}\n' > "$db_work/section-main.json"
  jq -n --arg config "$db_work/section-main.json" '[{section:"main",config:$config,dnsPort:19602,proxyPort:19603}]' > "$db_work/sections.json"
}
printf 'MemAvailable: 65000 kB\n' > "$fixture_dir/meminfo"
db_action=pair_test
db_child_start udp 1.1.1.1 8.8.8.8 udp pair || fail "protected child startup: $db_child_error"
db_child_stop
[ "$(wc -l < "$OOM_TRACE")" = 4 ] || fail 'front/worker check/run coverage missing'
awk -F'|' '$2!=1000 {bad=1} END {exit bad}' "$OOM_TRACE" || fail 'private check/run not preferred OOM victims'
awk -F'|' '$3!=25 || $4!="unset" {bad=1} END {exit bad}' "$OOM_TRACE" || fail 'private Go profile changed'
read -r current_score < /proc/self/oom_score_adj
[ "$current_score" = "$parent_score" ] || fail 'coordinator OOM score modified'
read -r current_score < "/proc/$production/oom_score_adj"
[ "$current_score" = "$production_score" ] || fail 'production sentinel OOM score modified'
[ "$GOGC|$GOMEMLIMIT" = '100|800MiB' ] || fail 'parent Go environment modified'
# Simulate the kernel-write failure at the printf syscall boundary, without
# replacing the real private-check launcher or changing any production score.
(
  OOM_TRACE="$fixture_dir/refused-trace"; export OOM_TRACE
  printf() { case "$1" in '1000\n') return 1;; *) command printf "$@";; esac; }
  if db_check_config "$db_work/child.json"; then fail 'OOM score write failure accepted'; fi
  [ ! -e "$OOM_TRACE" ] || fail 'sing-box executed despite OOM protection failure'
)
echo 'PASS: private front/worker check/run OOM score1000, parent/production unchanged, Go profile unchanged, write failure refuses exec'
