#!/bin/sh
set -eu
# Explicit compatibility fixture for the former split worker architecture.
export PODKOP_SECTION_MODE=split
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
script="${PODKOP_SECTION_RUNTIME_TEST_SOURCE:-$repo/openwrt/podkop-section-runtime}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
jq -n '{
  log:{level:"warn"},
  experimental:{cache_file:{enabled:true,path:"/tmp/production-cache.db"},clash_api:{external_controller:"0.0.0.0:9090",secret:"production-token"},other_setting:"must-not-copy"},
  dns:{servers:[{type:"udp",tag:"real",server:"1.1.1.1"},{type:"fakeip",tag:"fakeip-server",inet4_range:"198.18.0.0/15"}],final:"real",rules:[{action:"route",server:"fakeip-server",rule_set:["main-discord-community-ruleset"],rewrite_ttl:60},{action:"route",server:"fakeip-server",domain:["fakeip.podkop.fyi","ip.podkop.fyi"],rewrite_ttl:60}]},
  inbounds:[{type:"mixed",tag:"main-mixed-in",listen:"127.0.0.1",listen_port:18000}],
  outbounds:[{type:"direct",tag:"direct-out"},{type:"selector",tag:"main-out",outbounds:["main-1-out"],default:"main-1-out"},{type:"socks",tag:"main-1-out",server:"127.0.0.1",server_port:10800},{type:"selector",tag:"GEOBLOCK-out",outbounds:["GEOBLOCK-1-out"],default:"GEOBLOCK-1-out"},{type:"socks",tag:"GEOBLOCK-1-out",server:"127.0.0.1",server_port:10801}],
  route:{default_domain_resolver:"real",final:"direct-out",rules:[{rule_set:["main-discord-community-ruleset"],outbound:"main-out"}],rule_set:[{type:"inline",tag:"main-discord-community-ruleset",rules:[{domain_suffix:["discord.com"]},{domain_suffix:["discord.gg"]}]}]}
}' > "$work/base.json"
for mode in true false absent; do
  jq --arg mode "$mode" 'if $mode=="absent" then . else .experimental.utls_fallback={enabled:($mode=="true"),fingerprints:["safari","randomized","edge","firefox","chrome"]} end' "$work/base.json" > "$work/logical-$mode.json"
  for section in main GEOBLOCK; do
    case "$section" in main) port=18100; api=19100;; GEOBLOCK) port=18101; api=19101;; esac
    output="$work/$mode-$section"
    sh "$script" split-one "$work/logical-$mode.json" "$section" "$port" "$api" "$output" || fail "$mode/$section split failed"
    jq -e --slurpfile logical "$work/logical-$mode.json" '
      (.experimental.utls_fallback==$logical[0].experimental.utls_fallback) and
      (.experimental|has("utls_fallback"))==($logical[0].experimental|has("utls_fallback"))
    ' "$output/worker.json" >/dev/null || fail "$mode/$section lost opt-in/off/default uTLS fallback"
    jq -e --argjson port "$port" --arg api "127.0.0.1:$api" '
      (.experimental|keys|sort)==(["clash_api"]+(if .experimental|has("utls_fallback") then ["utls_fallback"] else [] end)|sort) and
      .experimental.clash_api=={external_controller:$api} and
      .experimental.cache_file==null and .experimental.other_setting==null and
      .inbounds==[{type:"mixed",tag:"section-in",listen:"127.0.0.1",listen_port:$port}] and
      (.dns.servers|all(.type!="fakeip")) and .dns.rules==null and
      .route.default_mark==2097152
    ' "$output/worker.json" >/dev/null || fail "$mode/$section leaked production state or wrong private listeners"
    jq -e --slurpfile logical "$work/logical-$mode.json" --arg section "$section" --argjson port "$port" '
      .dns==$logical[0].dns and .experimental==$logical[0].experimental and .route==$logical[0].route and
      any(.outbounds[];.tag==($section+"-out") and .type=="socks" and .server_port==$port)
    ' "$output/frontend.json" >/dev/null || fail "$mode/$section changed split FakeIP rules or frontend state"
  done
done
if [ -n "${PODKOP_PE_0724_FIXTURE_DIR:-}" ]; then
  [ ! -e "$PODKOP_PE_0724_FIXTURE_DIR" ] || fail 'fixture export directory already exists'
  mkdir -m 700 "$PODKOP_PE_0724_FIXTURE_DIR"
  jq 'del(.experimental.other_setting)' "$work/logical-true.json" > "$PODKOP_PE_0724_FIXTURE_DIR/logical.json"
  cp "$work/true-main/worker.json" "$PODKOP_PE_0724_FIXTURE_DIR/main-worker.json"
  cp "$work/true-GEOBLOCK/worker.json" "$PODKOP_PE_0724_FIXTURE_DIR/GEOBLOCK-worker.json"
  jq 'del(.experimental.other_setting)' "$work/true-main/frontend.json" > "$PODKOP_PE_0724_FIXTURE_DIR/frontend.json"
  chmod 600 "$PODKOP_PE_0724_FIXTURE_DIR"/*.json
fi
echo 'PE 0.7.24 section runtime tests: OK'
