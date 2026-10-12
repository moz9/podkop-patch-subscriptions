#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_SECTION_ROOT="$work/section-runtime"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v db_worker_configs >/dev/null || fail 'native V1 worker enumeration missing'
mkdir -p "$PODKOP_SECTION_ROOT"
printf '%s\n' '{"section":"main","port":19160,"api_port":19163}' > "$PODKOP_SECTION_ROOT/metadata.json"
printf '%s\n' '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":19160}]}' > "$PODKOP_SECTION_ROOT/worker.json"
[ "$(db_worker_configs)" = "$PODKOP_SECTION_ROOT/worker.json" ] || fail 'native single worker not enumerated'
[ "$(db_worker_section "$PODKOP_SECTION_ROOT/worker.json")" = main ] || fail 'native section metadata not used'
db_prepare
db_work="$work/clone"
mkdir -p "$db_work"
PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
printf 'MemAvailable: 42000 kB\n' > "$work/meminfo"
[ "$(db_parallel_limit)" = 1 ] || fail 'legacy DNS must stay serial'
db_runtime_safe || fail 'legacy memory floor incorrectly requires PE128MB'
printf 'MemAvailable: 15000 kB\n' > "$work/meminfo"
if db_runtime_safe; then fail 'low memory continued cloning'; fi
[ "$db_child_error" = memory_pressure ] || fail 'memory abort reason absent'
printf 'MemTotal: 128000 kB\n' > "$work/meminfo"
if db_runtime_safe; then fail 'unknown memory continued'; fi
printf 'MemAvailable: 42000 kB\n' > "$work/meminfo"
jq -n '{dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"8.8.8.8"},{type:"udp",tag:"dns-server",server:"1.1.1.1"}],final:"dns-server",rules:[]},inbounds:[{type:"tproxy",tag:"tproxy-in",listen_port:1602}],outbounds:[{type:"direct",tag:"direct-out"},{type:"socks",tag:"main-out",server:"127.0.0.1",server_port:19160}],route:{final:"direct-out",rules:[{domain_suffix:["youtube.com"],outbound:"main-out"}],rule_set:[]}}' > "$work/front.json"
jq -n '{dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"8.8.8.8"},{type:"udp",tag:"dns-server",server:"1.1.1.1"}],final:"dns-server"},inbounds:[{type:"socks",tag:"section-in",listen:"127.0.0.1",listen_port:19160}],outbounds:[{type:"selector",tag:"main-out",outbounds:["main-1-out","main-2-out"]},{type:"trojan",tag:"main-1-out",server:"a.example",password:"a"},{type:"trojan",tag:"main-2-out",server:"b.example",password:"b"},{type:"direct",tag:"direct-out"}],route:{final:"main-out",default_domain_resolver:"dns-server"},experimental:{clash_api:{external_controller:"127.0.0.1:19163"}}}' > "$PODKOP_SECTION_ROOT/worker.json"
db_runtime_path() { printf '%s/front.json\n' "$work"; }
db_snapshot_choices() { printf '%s\n' '{"proxies":{"main-out":{"now":"main-2-out"}}}' > "$2"; }
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$work/native-clone.json" udp || fail "native SOCKS worker clone failed: $db_child_error"
jq -e '.outbounds[]|select(.tag=="main-out")|.server_port==19603' "$work/native-clone.json" >/dev/null || fail 'front clone still points at production worker'
jq -e '.outbounds[]|select(.tag=="main-out")|.default=="main-2-out"' "$db_work/section-main.json" >/dev/null || fail 'native worker live choice was lost'
jq -e '.[0].section=="main" and .[0].proxyPort==19603' "$db_work/sections.json" >/dev/null || fail 'wrong native section identity'
echo 'PASS: native V1 worker, correct section identity, serial and bounded memory guard'
