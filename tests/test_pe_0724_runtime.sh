#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
lib="$repo/openwrt/runtime-0.7.24/usr/lib/podkop"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -s "$runtime" ] || fail '0.7.24 runtime is absent'
[ -s "$lib/constants.sh" ] || fail '0.7.24 constants bundle is absent'
sh -n "$runtime"
for file in "$lib"/*.sh; do sh -n "$file"; done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
# Official helper module is installed by Podkop; only relocate its import path.
sed "s@\"search\": \"/usr/lib/podkop\"@\"search\": \"$repo/tests/fixtures/podkop-jq\"@g" "$lib/sing_box_config_manager.sh" > "$work/manager"
. "$work/manager"
. "$lib/constants.sh"
[ "$PODKOP_VERSION" = 0.7.24 ] || fail 'bundled compiled runtime version is not 0.7.24'
sed -n '/^show_version() {$/,/^}$/p' "$runtime" > "$work/version"
. "$work/version"
[ "$(show_version)" = 0.7.24 ] || fail 'show_version did not expose compiled constant'
# Podkop executes without nounset; optional library arguments use that contract.
set +u
[ "$SB_FAKEIP_SERVICE_DNS_RULE_TAG" = fakeip-service-dns-rule-tag ] || fail 'service DNS tag'
[ "$SB_UTLS_FALLBACK_FINGERPRINTS" = safari,randomized,edge,firefox,chrome ] || fail 'fingerprint order'
log() { :; }
config_get() { eval "$1=\${4:-}"; }
config_get_bool() {
    case "$3" in enable_utls_fallback) eval "$1=\${ENABLED:-${4:-0}}";; *) eval "$1=\${4:-0}";; esac
}
get_service_listen_address() { printf '127.0.0.1\n'; }
sing_box_has_feature() { [ "$1" = tls.utls-fallback ] && [ "${CAPABILITY:-0}" = 1 ]; }
comma_string_to_json_array() { printf '%s' "$1" | jq -Rc 'split(",")'; }
url_get_host() { printf '%s\n' "$1"; }
is_ipv4() { return 0; }
sing_box_cf_add_dns_server() { printf '%s\n' "$1"; }
sed -n '/^load_active_dns_settings() {$/,/^}$/p; /^sing_box_configure_dns() {$/,/^}$/p' "$runtime" > "$work/dns"
sed -n '/^sing_box_configure_experimental() {$/,/^}$/p' "$runtime" > "$work/experimental"
. "$work/dns"
. "$work/experimental"
config='{"dns":{"servers":[],"rules":[]},"experimental":{}}'
sing_box_configure_dns
printf '%s' "$config" | jq -e --arg lists "$SB_FAKEIP_DNS_RULE_TAG" --arg service "$SB_FAKEIP_SERVICE_DNS_RULE_TAG" '
    ([.dns.rules[]|select(.__service_tag==$lists)] | length)==1
    and ([.dns.rules[]|select(.__service_tag==$lists)][0] | has("domain")|not)
    and ([.dns.rules[]|select(.__service_tag==$service)][0].domain)==["fakeip.podkop.fyi","ip.podkop.fyi"]
' >/dev/null || fail 'service domain and list FakeIP rules are not separate'
sing_box_cm_save_config_to_file "$config" "$work/no-lists.json"
jq -e '[.dns.rules[]|select(.action=="route")]|length==1' "$work/no-lists.json" >/dev/null || fail 'conditionless FakeIP route was saved'
config="$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" rule_set '["discord"]')"
sing_box_cm_save_config_to_file "$config" "$work/with-lists.json"
jq -e '[.dns.rules[]|select(.action=="route")]|length==2 and (.[0].rule_set==["discord"] and (.[0]|has("domain")|not)) and (.[1].domain|length==2) and (.[1]|has("rule_set")|not)' "$work/with-lists.json" >/dev/null || fail 'FakeIP OR semantics lost with a list'
printf '%s' '{"dns":{"rules":[{"action":"route","server":"real","rewrite_ttl":60,"__service_tag":"empty"},{"action":"route","server":"real","query_type":["A"]},{"action":"reject"}]}}' > "$work/input.json"
sing_box_cm_save_config_to_file "$(cat "$work/input.json")" "$work/saved.json"
jq -e '.dns.rules==[{action:"route",server:"real",query_type:["A"]},{action:"reject"}]' "$work/saved.json" >/dev/null || fail 'conditionless filtering altered conditional/reject rules'
for state in 'unset:1:no' '0:1:no' '1:0:no' '1:1:yes'; do
    ENABLED="${state%%:*}"; rest="${state#*:}"; CAPABILITY="${rest%%:*}"; expected="${rest#*:}"
    [ "$ENABLED" != unset ] || unset ENABLED
    config='{"experimental":{}}'
    sing_box_configure_experimental
    if [ "$expected" = yes ]; then
        printf '%s' "$config" | jq -e '.experimental.utls_fallback=={enabled:true,fingerprints:["safari","randomized","edge","firefox","chrome"]}' >/dev/null || fail 'supported uTLS fallback not configured'
    else
        printf '%s' "$config" | jq -e '.experimental|has("utls_fallback")|not' >/dev/null || fail 'uTLS fallback emitted when disabled/unsupported'
    fi
done
probe_input='{"dns":{"servers":[],"rules":[]},"route":{},"outbounds":[{"type":"direct","tag":"target"}],"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090"},"cache_file":{"enabled":true},"utls_fallback":{"enabled":true,"fingerprints":["safari","chrome"]}}}'
for probe_source in "$repo/openwrt/podkop-subscription-probe.sh" "$runtime"; do
    sed -n '/^subscription_probe_config() {$/,/^}$/p' "$probe_source" > "$work/probe"
    . "$work/probe"
    subscription_probe_config "$probe_input" target 43123 | jq -e '.experimental=={utls_fallback:{enabled:true,fingerprints:["safari","chrome"]}} and .inbounds[0].listen=="127.0.0.1"' >/dev/null || fail "uTLS fallback dropped/leaked shared experimental fields: $probe_source"
    subscription_probe_config "$(printf '%s' "$probe_input"|jq 'del(.experimental.utls_fallback)')" target 43123 | jq -e 'has("experimental")|not' >/dev/null || fail 'empty experimental object retained'
done
for file in helpers.sh sing_box_config_facade.sh; do
    cmp "$lib/$file" "$repo/openwrt/runtime-0.7.23/usr/lib/podkop/$file" || fail "snapshot drift: $file"
done
printf 'PASS: PE 0.7.24 FakeIP rules, save filtering, gated uTLS fallback and private probe context\n'
