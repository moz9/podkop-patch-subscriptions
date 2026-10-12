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
export GOGC=100 GOMEMLIMIT=800MiB
export GC_TRACE="$fixture_dir/env-trace"
mkdir "$fixture_dir/bin"
cat > "$fixture_dir/bin/sing-box" <<'SCRIPT'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$1" "${GOGC:-unset}" "${GOMEMLIMIT:-unset}" "$4" >> "$GC_TRACE"
if [ "$1" = run ]; then exec sleep 60; fi
SCRIPT
chmod +x "$fixture_dir/bin/sing-box"
PATH="$fixture_dir/bin:$PATH"; export PATH
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
printf 'MemAvailable: 42000 kB\n' > "$fixture_dir/meminfo"
netstat() { return 0; }
dig() { echo 93.184.216.34; }
db_make_pair_config() {
  printf '{}\n' > "$4"; printf '{}\n' > "$db_work/section-main.json"
  jq -n --arg config "$db_work/section-main.json" '[{section:"main",config:$config,dnsPort:19602,proxyPort:19603}]' > "$db_work/sections.json"
}
db_action=pair_test
db_child_start udp 1.1.1.1 8.8.8.8 udp pair || fail "child startup: $db_child_error"
db_child_stop
[ "$GOGC|$GOMEMLIMIT" = '100|800MiB' ] || fail 'test profile leaked into parent environment'
[ "$(wc -l < "$GC_TRACE")" = 4 ] || fail 'front/worker check/run profile not observed'
awk -F'|' '$2!=25 || $3!="unset" {bad=1} END {exit bad}' "$GC_TRACE" || fail 'isolated check/run missing child-only GOGC25 or inherited soft cap'
echo 'PASS: front/worker check/run GOGC25 scoped only to children, no inherited GOMEMLIMIT, owned cleanup and unchanged parent environment'
