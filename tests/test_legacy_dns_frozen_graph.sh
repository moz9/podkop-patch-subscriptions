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
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
jq -n '{dns:{servers:[{type:"udp",tag:"bootstrap",server:"8.8.8.8"},{type:"https",tag:"dns-server",server:"old.example",domain_resolver:"bootstrap"}],final:"dns-server",rules:[{domain_suffix:["test.example"],server:"dns-server"}]},outbounds:[{type:"selector",tag:"selected",outbounds:["inactive","nested"],default:"inactive"},{type:"urltest",tag:"nested",outbounds:["active","inactive"],default:"inactive",url:"https://probe.example"},{type:"trojan",tag:"active",server:"active.example",password:"active-secret",detour:"dial",domain_resolver:{server:"dns-server",strategy:"ipv4_only"}},{type:"direct",tag:"dial",domain_resolver:"dns-server"},{type:"trojan",tag:"inactive",server:"inactive.example",password:"inactive-secret"},{type:"direct",tag:"route-extra"},{type:"direct",tag:"orphan"}],route:{final:"selected",default_domain_resolver:"dns-server",rules:[{type:"logical",mode:"or",rules:[{domain_suffix:["extra.example"],outbound:"route-extra"}]}],rule_set:[]},experimental:{clash_api:{external_controller:"127.0.0.1:9090"}}}' > "$fixture_dir/runtime.json"
printf '{"proxies":{"selected":{"now":"nested"},"nested":{"now":"active"}}}\n' > "$fixture_dir/choices.json"
sha256sum "$fixture_dir/runtime.json" "$fixture_dir/choices.json" > "$fixture_dir/source.sha"
db_clone_runtime udp 1.1.1.1 8.8.8.8 "$db_work/clone.json" udp "$fixture_dir/runtime.json" "$fixture_dir/choices.json" || fail "clone failed: $db_child_error"
jq -e '(.outbounds|map(.tag))==["selected","nested","active","dial","route-extra"] and .outbounds[0].outbounds==["nested"] and .outbounds[1].outbounds==["active"] and .outbounds[1].type=="selector" and .outbounds[2].password=="active-secret" and .outbounds[2].detour=="dial" and .outbounds[2].domain_resolver=={server:"dns-server",strategy:"ipv4_only"} and .dns.rules[0].server=="dns-server" and .route.rules[1].rules[0].outbound=="route-extra"' "$db_work/clone.json" >/dev/null || fail 'frozen graph retained inactive branches or lost reachable policy'
sha256sum -c "$fixture_dir/source.sha" >/dev/null || fail 'pruning changed production inputs'
for members in '"nested-unused"' '["nested",""]' '["nested",false]' '["nested","nested"]'; do
  jq --argjson members "$members" '.outbounds[0].outbounds=$members' "$fixture_dir/runtime.json" > "$fixture_dir/bad-group.json"
  if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$db_work/bad-group-clone.json" udp "$fixture_dir/bad-group.json" "$fixture_dir/choices.json"; then fail "malformed original selector members repaired: $members"; fi
  [ "$db_child_error" = active_selection_unavailable ] || fail 'malformed source-group error lost'
done

# Every non-route dial root, including DNS and ruleset download, remains live.
jq '.dns.servers[0].detour="inactive"|.route.rule_set=[{type:"inline",tag:"sample",rules:[],download_detour:"orphan"}]|.ntp={enabled:true,detour:"route-extra"}' "$db_work/clone.json" > "$fixture_dir/roots.json"
jq --slurpfile original "$fixture_dir/runtime.json" '.outbounds += [$original[0].outbounds[]|select(.tag=="inactive" or .tag=="orphan")]' "$fixture_dir/roots.json" > "$fixture_dir/with-roots.json"
db_prune_frozen_outbounds "$fixture_dir/with-roots.json" || fail 'DNS/download/NTP roots rejected'
jq -e '(.outbounds|map(.tag)|sort)==["active","dial","inactive","nested","orphan","route-extra","selected"] and .dns.servers[0].detour=="inactive" and .route.rule_set[0].download_detour=="orphan"' "$fixture_dir/with-roots.json" >/dev/null || fail 'dial root lost'
jq 'del(.route.final)|.route.rules=[]|.outbounds=[{type:"direct",tag:"first"},{type:"direct",tag:"unused"}]' "$db_work/clone.json" > "$fixture_dir/implicit.json"
db_prune_frozen_outbounds "$fixture_dir/implicit.json" || fail 'implicit route final rejected'
jq -e '.outbounds|map(.tag)==["first"]' "$fixture_dir/implicit.json" >/dev/null || fail 'implicit first outbound changed'
for mutation in missing detour malformed duplicate unknown nested; do
  jq --arg mutation "$mutation" '
    if $mutation=="missing" then .route.final="missing"
    elif $mutation=="detour" then .outbounds[2].detour="missing"
    elif $mutation=="malformed" then .route.rules[1].outbound={tag:"active"}
    elif $mutation=="duplicate" then .outbounds += [.outbounds[0]]
    elif $mutation=="unknown" then .outbounds[2].type="unknown-protocol"
    else .outbounds[2].transport={outbounds:["missing"]} end' "$db_work/clone.json" > "$fixture_dir/reject.json"
  sha256sum "$fixture_dir/reject.json" > "$fixture_dir/reject.sha"
  if db_prune_frozen_outbounds "$fixture_dir/reject.json"; then fail "unsupported reference accepted: $mutation"; fi
  [ "$db_child_error" = unsupported_outbound_graph ] || fail 'missing actionable graph refusal'
  sha256sum -c "$fixture_dir/reject.sha" >/dev/null || fail 'failed pruning partially replaced graph'
done
echo 'PASS: active transitive graph only, exact selectors/credentials/resolvers, DNS/download roots, implicit final and fail-closed references'
