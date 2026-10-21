#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
printf '#!/bin/sh\nprintf "sing-box version fixture\\nTags: with_utls\\n"\n' > "$work/engine"
chmod 700 "$work/engine"
export PODKOP_DNS_BENCHMARK_BIN="$work/engine" PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer" PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work"; db_worker_pid=0
jq -n '{dns:{servers:[{tag:"dns-server",type:"udp",server:"8.8.8.8"}],final:"dns-server"},outbounds:[{type:"direct",tag:"direct"},{type:"selector",tag:"selected",outbounds:["direct"]}],route:{final:"selected",rules:[]},inbounds:[]}' > "$work/runtime"
echo '{"proxies":{}}' > "$work/choices"
db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/clone" udp "$work/runtime" "$work/choices" || fail 'unambiguous single member refused'
jq -e '.outbounds|any(.tag=="selected" and .type=="selector" and .default=="direct")' "$work/clone" >/dev/null || fail 'wrong deterministic selection'
jq '.outbounds[1].outbounds=["direct","other"] | .outbounds += [{type:"direct",tag:"other"}]' "$work/runtime" > "$work/multiple"
if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/clone" udp "$work/multiple" "$work/choices"; then fail 'ambiguous selection guessed'; fi
echo '{"proxies":{"selected":{"now":"foreign"}}}' > "$work/choices"
if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/clone" udp "$work/runtime" "$work/choices"; then fail 'contradictory active selection accepted'; fi
echo 'PASS: single-member choice works without redundant API data; ambiguous/foreign choices fail closed'
