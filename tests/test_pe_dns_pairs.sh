#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_DNS_OPTIMIZER_STATE_DIR="$work/optimizer-state" PODKOP_DNS_OPTIMIZER_PERSIST_DIR="$work/optimizer-persist"
export PODKOP_MUTATION_LOCK_DIR="$work/mutation" PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/legacy"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare
db_work="$work"; db_worker_pid=0; db_report_id=pairs-report
jq -n '{log:{level:"info"},experimental:{cache_file:{enabled:true,path:"/tmp/live.db"},clash_api:{external_controller:"127.0.0.1:9090",secret:"private-token"}},dns:{servers:[{tag:"bootstrap",type:"udp",server:"8.8.8.8"},{tag:"dns-server",type:"https",server:"old.example",domain_resolver:"bootstrap"},{tag:"fakeip",type:"fakeip",inet4_range:"198.18.0.0/15"}],final:"dns-server",rules:[{rule_set:["media"],server:"dns-server"},{query_type:["A"],server:"fakeip"}]},inbounds:[{type:"tproxy",tag:"tproxy-in",listen_port:1602},{type:"direct",tag:"dns-in",listen_port:53}],outbounds:[{type:"direct",tag:"direct",domain_resolver:"dns-server"},{type:"selector",tag:"selected",outbounds:["node-a","node-b"],default:"node-a"},{type:"urltest",tag:"auto",outbounds:["node-a","node-b"]},{type:"trojan",tag:"node-a",server:"a.example",password:"secret-a"},{type:"trojan",tag:"node-b",server:"b.example",password:"secret-b"}],route:{default_domain_resolver:"dns-server",final:"selected",rules:[{inbound:["tproxy-in"],action:"sniff"},{inbound:"tproxy-in",rule_set:["media"],outbound:"auto"},{protocol:"dns",action:"hijack-dns"}],rule_set:[{type:"inline",tag:"media",rules:[{domain_suffix:["example.com"]}]}]}}' > "$work/runtime.json"
jq -n '{proxies:{selected:{now:"node-b"},auto:{now:"node-a"}}}' > "$work/choices.json"
db_clone_runtime doh cloudflare-dns.com/dns-query 8.8.8.8 "$work/clone.json" udp "$work/runtime.json" "$work/choices.json" || fail 'runtime cloning failed'
jq -e '.experimental==null and .endpoints==null and (.inbounds|length)==2 and .inbounds[0].listen=="127.0.0.1" and .inbounds[1].type=="mixed" and .inbounds[1].listen_port==19554 and .route.default_mark==2097152 and .route.final=="selected" and .route.rule_set[0].tag=="media" and .route.rules[1].inbound==["http-in"] and .dns.servers[1].tag=="dns-server" and .dns.servers[1].server=="cloudflare-dns.com" and (.dns.servers|all(.type!="fakeip")) and .dns.rules[1].server=="dns-server" and .outbounds[1].default=="node-b" and .outbounds[2].type=="selector" and .outbounds[2].default=="node-a" and .outbounds[4].password=="secret-b"' "$work/clone.json" >/dev/null || fail 'clone lost active routes, DNS references, credentials or selected nodes'
jq -e '.route.rules[2].inbound=="http-in"' "$work/clone.json" >/dev/null || fail 'string inbound rule was not remapped'
jq() {
    case "$*" in *'test('*) printf 'jq: test is unavailable without ONIGURUMA\n' >&2; return 3;; esac
    command jq "$@"
}
db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/no-regex-clone.json" udp "$work/runtime.json" "$work/choices.json" || fail 'ordinary clone requires jq ONIGURUMA regex build'
unset -f jq
for predicate in source_ip_cidr source_ip_is_private source_port source_port_range source_mac_address process_name process_path process_path_regex package_name user user_id network_type network_is_expensive network_is_constrained wifi_ssid wifi_bssid interface_name rule_set_ip_cidr_match_source; do
    jq --arg predicate "$predicate" '.route.rules[1][$predicate]=["192.168.44.0/24"]' "$work/runtime.json" > "$work/client-routing.json"
    if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/client-clone.json" udp "$work/client-routing.json" "$work/choices.json"; then fail "loopback clone accepted client-sensitive $predicate"; fi
    [ "$db_child_error" = unsupported_client_routing ] || fail 'client route rejection lacks actionable reason'
done
jq '.route.rules[1]={type:"logical",mode:"and",rules:[{source_ip_cidr:["192.168.44.0/24"]},{domain_suffix:["example.com"]}],outbound:"selected"}' "$work/runtime.json" > "$work/client-routing.json"
if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/client-clone.json" udp "$work/client-routing.json" "$work/choices.json"; then fail 'nested client-sensitive routing accepted'; fi
jq '.dns.rules[0].source_ip_cidr=["192.168.44.0/24"]' "$work/runtime.json" > "$work/client-routing.json"
if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/client-clone.json" udp "$work/client-routing.json" "$work/choices.json"; then fail 'client-sensitive DNS routing accepted'; fi
[ "$(stat -c %a "$work/clone.json")" = 600 ] || fail 'runtime credentials file is not private'
jq '.endpoints=[{type:"wireguard",tag:"wg"}]' "$work/runtime.json" > "$work/endpoint.json"
if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/unsupported.json" udp "$work/endpoint.json" "$work/choices.json"; then fail 'kernel-mutating endpoints accepted'; fi
jq -n '{proxies:{}}' > "$work/no-choices.json"
if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/unsupported.json" udp "$work/runtime.json" "$work/no-choices.json"; then fail 'unknown current selector was guessed'; fi
printf 'rule-cache-fixture' > "$work/live-cache.db"
jq --arg cache "$work/live-cache.db" '.experimental.cache_file.path=$cache|.route.rule_set=[{type:"remote",tag:"main-youtube-community-ruleset",url:"https://github.com/itdoginfo/allow-domains/releases/latest/download/youtube.srs",format:"binary"}]|.route.rules[1].rule_set=["main-youtube-community-ruleset"]|.dns.rules[0].rule_set=["main-youtube-community-ruleset"]' "$work/runtime.json" > "$work/cached-runtime.json"
db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/cached-clone.json" udp "$work/cached-runtime.json" "$work/choices.json" || fail 'cached rules clone rejected'
jq -e --arg original "$work/live-cache.db" '.experimental.clash_api==null and .experimental.cache_file.path!=$original and .experimental.cache_file.store_fakeip==false and .experimental.cache_file.store_rdrc==false' "$work/cached-clone.json" >/dev/null || fail 'child reuses production cache or Clash listener'
cmp "$work/live-cache.db" "$(jq -r '.experimental.cache_file.path' "$work/cached-clone.json")" || fail 'current rule-set cache not preserved'
for mutation in arbitrary_remote local spoofed_tag url_query custom_path unknown_community wrong_format; do
    jq --arg mutation "$mutation" '
      if $mutation=="arbitrary_remote" then .route.rule_set[0].url="https://rules.example/live.srs"
      elif $mutation=="local" then .route.rule_set[0]={type:"local",tag:"main-youtube-community-ruleset",path:"/tmp/arbitrary.srs",format:"binary"}
      elif $mutation=="spoofed_tag" then .route.rule_set[0].tag="main-discord-community-ruleset"
      elif $mutation=="url_query" then .route.rule_set[0].url+="?custom=1"
      elif $mutation=="custom_path" then .route.rule_set[0].url="https://github.com/itdoginfo/allow-domains/releases/latest/download/custom/youtube.srs"
      elif $mutation=="unknown_community" then .route.rule_set[0].url="https://github.com/itdoginfo/allow-domains/releases/latest/download/arbitrary.srs"|.route.rule_set[0].tag="main-arbitrary-community-ruleset"
      else .route.rule_set[0].format="source" end' "$work/cached-runtime.json" > "$work/arbitrary-rules.json"
    if db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/arbitrary-clone.json" udp "$work/arbitrary-rules.json" "$work/choices.json"; then fail "uninspected $mutation rule set accepted"; fi
    [ "$db_child_error" = unsupported_ruleset_routing ] || fail 'uninspected rule set rejection lacks actionable reason'
done
awk '/^var DOMAIN_LIST_OPTIONS =/ {inside=1;next} inside && /^};/ {exit} inside {sub(/:.*/,"",$1);print $1}' "$repo/openwrt/main.js" | jq -Rsc 'split("\n")|map(select(.!=""))' > "$work/native-community-tags.json"
jq --slurpfile communities "$work/native-community-tags.json" '.route.rule_set=[$communities[0][]|{type:"remote",tag:("main-"+.+"-community-ruleset"),url:("https://github.com/itdoginfo/allow-domains/releases/latest/download/"+.+".srs"),format:"binary"}]' "$work/cached-runtime.json" > "$work/all-native-runtime.json"
db_clone_runtime udp 1.1.1.1 8.8.8.8 "$work/all-native-clone.json" udp "$work/all-native-runtime.json" "$work/choices.json" || fail 'trusted community tags drifted from native LuCI options'
db_make_config tcp 1.1.1.1 8.8.8.8 "$work/tcp.json" doh
jq -e '.dns.servers[0].type=="https" and .dns.servers[0].server=="8.8.8.8" and .dns.servers[0].tls.server_name=="dns.google" and .dns.servers[1].type=="tcp"' "$work/tcp.json" >/dev/null || fail 'typed bootstrap lost TLS name or main TCP transport'
db_make_config dot 'custom.example:8853' 8.8.8.8 "$work/custom-port.json"
jq -e '.dns.servers[1].server=="custom.example" and .dns.servers[1].server_port==8853' "$work/custom-port.json" >/dev/null || fail 'custom TLS port lost'
db_make_config doh 8.8.8.8 8.8.8.8 "$work/bootstrap-role.json" doh bootstrap
jq -e '.dns.servers[1].server=="8.8.8.8" and .dns.servers[1].tls.server_name=="dns.google"' "$work/bootstrap-role.json" >/dev/null || fail 'bootstrap measurement substituted a hostname instead of IP endpoint'
choice_variant=one
uci() { case "$*" in *export*) echo 'config settings';; *config_path*) echo "$work/runtime.json";; *) return 1;; esac; }
ip() { echo '2: br-lan inet 192.168.44.1/24 scope global br-lan'; }
curl() {
    local output='' header='' previous='' argument
    for argument in "$@"; do
        case "$argument" in *private-token*) fail 'API secret exposed in argv';; esac
        case "$previous" in -o) output="$argument";; --header) header="${argument#@}";; esac
        previous="$argument"
    done
    [ "$(stat -c %a "$header")" = 600 ] || fail 'auth header file is not private'
    grep -q '^Authorization: Bearer private-token$' "$header" || fail 'API authentication missing'
    if [ "$choice_variant" = one ]; then cp "$work/choices.json" "$output"; else jq '.proxies.selected.now="node-a"' "$work/choices.json" > "$output"; fi
}
fingerprint_one="$(db_fingerprint)"; choice_variant=two; fingerprint_two="$(db_fingerprint)"
[ "$fingerprint_one" != "$fingerprint_two" ] || fail 'proof fingerprint ignores actual active group choice'
jq '.experimental.clash_api.external_controller="192.168.44.1:9090"' "$work/runtime.json" > "$work/lan-runtime.json"
db_snapshot_choices "$work/lan-runtime.json" "$work/lan-choices.json" || fail 'local LAN interface-bound Clash API rejected'
jq '.experimental.clash_api.external_controller="192.0.2.9:9090"' "$work/runtime.json" > "$work/remote-runtime.json"
if db_snapshot_choices "$work/remote-runtime.json" "$work/remote-choices.json"; then fail 'remote controller allowed'; fi
http_mode=ok
curl() {
    local output='' previous='' argument proxy='' noproxy=unset
    for argument in "$@"; do
        case "$previous" in -o) output="$argument";; --proxy) proxy="$argument";; --noproxy) noproxy="$argument";; esac
        previous="$argument"
    done
    [ "$proxy" = socks5h://127.0.0.1:19554 ] && [ "$noproxy" = '' ] || return 22
    [ -z "${https_proxy:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ] || return 22
    printf '%064d' 0 > "$output"
    if [ "$http_mode" = denied ]; then printf 403; else printf 206; fi
}
HTTPS_PROXY=http://wrong-proxy; export HTTPS_PROXY
db_transport_guards || fail 'transport did not use candidate SOCKS DNS and routes'
http_mode=denied
if db_transport_guards; then fail 'candidate transport failure accepted'; fi
jq -e '.path=="candidate_podkop" and .reason=="unexpected_status"' "$DB_DIR/transport-error.json" >/dev/null
db_busy() { return 1; }; db_fingerprint() { echo fixture-fingerprint; }
db_child_start() { [ "${5:-}" = pair ] || fail 'pair measurement started DNS-only child'; return 0; }
db_child_stop() { :; }
db_measure() { printf '%s\n' '{"reliable":true,"averageMs":7,"successCount":8,"totalQueries":8}'; }
db_transport_guards() { return 0; }
db_results='[{"protocol":"udp","id":"cloudflare","dnsServer":"1.1.1.1","primaryEligible":true,"reliable":true},{"protocol":"udp","id":"yandex","dnsServer":"77.88.8.8","primaryEligible":false,"reliable":true},{"protocol":"udp","id":"bad","dnsServer":"9.9.9.9","primaryEligible":true,"reliable":false}]'
db_bootstrap_results='[{"id":"google","server":"8.8.8.8","reliable":true},{"id":"cloudflare","protocol":"tcp","server":"1.1.1.1","reliable":true}]'
db_pair_results='[]'; db_individual_complete=true; db_action=pairs; db_deadline=$(( $(date +%s)+300 ))
db_state running pairs starting 0 0 1 ''
db_pairs || fail 'measured matrix failed'
db_status | jq -e '.state=="done" and .action=="pairs" and .total==2 and (.pairResults|length)==2 and (.pairResults|all(.success and .stats.reliable)) and .pairResults[0].bootstrapProtocol=="udp" and .pairResults[1].bootstrapProtocol=="tcp" and (.results|length)==3 and (.bootstrapResults|length)==2' >/dev/null || fail 'matrix report or measured candidate filtering wrong'
[ ! -s "$DB_PROOF" ] || fail 'matrix granted apply proof'
db_child_start() { db_child_error=listener_collision; return 1; }
db_pairs || fail 'one failed candidate aborted entire matrix'
db_status | jq -e '.state=="done" and (.pairResults|all(.success==false and .error=="listener_collision" and .stats==null))' >/dev/null || fail 'child failure was not reported per exact tuple'
db_child_start() { [ "${5:-}" = pair ] || fail 'pair measurement started DNS-only child'; return 0; }
db_results='[]'; db_pair_results='[]'
if db_pairs; then fail 'matrix guessed unmeasured candidates'; fi
db_status | jq -e '.error=="measured_candidates_required"' >/dev/null
db_results="$(jq -cn '[range(0;5)|{protocol:"udp",id:("c"+tostring),dnsServer:"1.1.1.1",reliable:true,primaryEligible:true}]')"
db_bootstrap_results="$(jq -cn '[range(0;5)|{server:"8.8.8.8",reliable:true}]')"
if db_pairs; then fail '25 pairs silently truncated'; fi
db_status | jq -e '.error=="too_many_pairs" and .total==25' >/dev/null
uci() {
    case "$*" in
        *bootstrap_dns_type*) echo tcp;;
        *dns_type*) echo dot;;
        *bootstrap_dns_server*) echo 8.8.8.8;;
        *dns_server*) echo 'custom.example:8853';;
        *) return 1;;
    esac
}
db_child_start() { [ "$1|$2|$3|$4" = 'dot|custom.example:8853|8.8.8.8|tcp' ]; }
probe="$(db_probe_pair primary)"
printf '%s' "$probe" | jq -e '.success==true and .slot=="primary" and .protocol=="dot" and .stats.reliable' >/dev/null || fail 'typed bootstrap health probe omitted real configured endpoint'
db_child_start() { db_child_error=listener_collision; return 1; }
probe="$(db_probe_pair primary)"
printf '%s' "$probe" | jq -e '.success==false and .error=="listener_collision"' >/dev/null || fail 'health probe startup failure not truthful'
echo 'PASS: exact current-route clones, candidate SOCKS transport and measured pair matrix'
