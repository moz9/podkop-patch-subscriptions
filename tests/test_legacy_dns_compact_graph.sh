#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$fixture_dir/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$fixture_dir/persist"
export PODKOP_SECTION_ROOT="$fixture_dir/native"
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir -p "$db_work" "$PODKOP_SECTION_ROOT"
jq -n '{rules:[{domain_suffix:[range(0;10000)|"host-\(.).example"]}]}' > "$fixture_dir/domains.json"
jq -n --arg path "$fixture_dir/domains.json" '{dns:{servers:[{type:"udp",tag:"bootstrap",server:"8.8.8.8"},{type:"udp",tag:"dns-server",server:"1.1.1.1"}],final:"dns-server",rules:[]},inbounds:[{type:"tproxy",tag:"tproxy-in",listen_port:1602}],outbounds:[{type:"direct",tag:"direct-out"},{type:"socks",tag:"main-out",server:"127.0.0.1",server_port:19160}],route:{final:"direct-out",rules:[{rule_set:["media"],outbound:"main-out"}],rule_set:[{type:"local",format:"source",tag:"media",path:$path}]}}' > "$fixture_dir/front.json"
jq -n '{dns:{servers:[{type:"udp",tag:"bootstrap",server:"8.8.8.8"},{type:"udp",tag:"dns-server",server:"1.1.1.1"}],final:"dns-server"},inbounds:[{type:"socks",tag:"section-in",listen:"127.0.0.1",listen_port:19160}],outbounds:[{type:"selector",tag:"main-out",outbounds:["main-1-out"]},{type:"trojan",tag:"main-1-out",server:"a.example",password:"private-fixture"},{type:"direct",tag:"direct-out"}],route:{final:"main-out"},experimental:{clash_api:{external_controller:"127.0.0.1:19163"}}}' > "$PODKOP_SECTION_ROOT/worker.json"
printf '{"section":"main","port":19160,"api_port":19163}\n' > "$PODKOP_SECTION_ROOT/metadata.json"
db_runtime_path() { printf '%s/front.json\n' "$fixture_dir"; }
db_snapshot_choices() { printf '{"proxies":{"main-out":{"now":"main-1-out"}}}\n' > "$2"; }
db_action=pair_test
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$db_work/baseline.json" udp || fail 'baseline clone failed'
jq -Sc . "$db_work/baseline.json" > "$fixture_dir/baseline.semantic"
jq -Sc . "$db_work/section-main.json" > "$fixture_dir/worker.semantic"
db_action=recommend_verified
db_prepare_runtime_cache fixed-context || fail 'prepared graph failed'
sha256sum "$DB_PREPARED_DIR"/*.json > "$fixture_dir/prepared.before"
# Reject the former full graph copy. The prepared JSON is immutable input;
# no caller is permitted to materialize another .source copy from it.
cp() { for argument in "$@"; do case "$argument" in "$DB_PREPARED_DIR"/*.json) fail 'immutable prepared graph was copied instead of shared';; esac; done; command cp "$@"; }
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$db_work/optimized.json" udp || fail 'prepared clone failed'
unset -f cp
sha256sum -c "$fixture_dir/prepared.before" >/dev/null || fail 'shared prepared graph was changed/deleted'
jq -Sc . "$db_work/optimized.json" > "$fixture_dir/optimized.semantic"
jq -Sc . "$db_work/section-main.json" > "$fixture_dir/optimized-worker.semantic"
cmp "$fixture_dir/baseline.semantic" "$fixture_dir/optimized.semantic" || fail 'representation optimization changed frontend graph'
cmp "$fixture_dir/worker.semantic" "$fixture_dir/optimized-worker.semantic" || fail 'representation optimization changed native section graph'
for graph in "$DB_PREPARED_DIR"/*.json "$db_work/optimized.json" "$db_work/section-main.json"; do
  [ "$(wc -l < "$graph")" = 1 ] || fail 'graph serialization is not compact'
done
[ ! -e "$db_work/optimized.json.source" ] || fail 'duplicate full frontend source remains'
jq -e '.route.rule_set[0].rules[0].domain_suffix|length==10000' "$db_work/optimized.json" >/dev/null || fail 'compact graph lost destinations'
jq . "$db_work/optimized.json" > "$fixture_dir/pretty.json"
compact_bytes="$(wc -c < "$db_work/optimized.json")"; pretty_bytes="$(wc -c < "$fixture_dir/pretty.json")"
[ "$compact_bytes" -lt "$pretty_bytes" ] || fail 'no compact representation savings'
echo "PASS: identical 10000-domain graph, immutable prepared sharing, compact bytes=$compact_bytes vs pretty=$pretty_bytes; memory guards unchanged"
