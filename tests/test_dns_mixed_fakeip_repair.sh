#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
sed '/^dns_apply_load() {$/,$d' "$repo/openwrt/podkop-dns-apply" > "$work/functions"
. "$work/functions"
cat > "$work/input" <<'JSON'
{"dns":{"servers":[{"tag":"dns-server","type":"https","server":"cloudflare-dns.com","detour":"keep"},{"tag":"bootstrap-dns-server","type":"udp","server":"77.88.8.8"}],"rules":[{"action":"reject","query_type":"HTTPS"},{"action":"route","server":"fakeip-server","rewrite_ttl":60,"domain":["fakeip.podkop.fyi","ip.podkop.fyi"],"rule_set":["discord","block"]},{"action":"route","server":"other","domain":"private.example","rule_set":"private"}]},"route":{"final":"direct"},"outbounds":[{"tag":"keep","type":"direct"}]}
JSON
jq '[.dns.servers[]]' "$work/input" > "$work/pair"
dns_apply_patch_json "$work/input" "$work/pair" "$work/output"
jq -e '.dns.rules[1]=={action:"route",server:"fakeip-server",rewrite_ttl:60,rule_set:["discord","block"]} and .dns.rules[2]=={action:"route",server:"fakeip-server",rewrite_ttl:60,domain:["fakeip.podkop.fyi","ip.podkop.fyi"]}' "$work/output" >/dev/null || { echo 'FAIL: mixed FakeIP rule still restricts Discord domains'; exit 1; }
jq -Sc 'del(.dns.rules)' "$work/input" > "$work/a"
jq -Sc 'del(.dns.rules)' "$work/output" > "$work/b"
cmp "$work/a" "$work/b"
jq -e '.dns.rules[0]=={action:"reject",query_type:"HTTPS"} and .dns.rules[3]=={action:"route",server:"other",domain:"private.example",rule_set:"private"}' "$work/output" >/dev/null
dns_apply_patch_json "$work/output" "$work/pair" "$work/twice"
cmp "$work/output" "$work/twice"
jq '.dns.rules[1].domain="fakeip.podkop.fyi"|.dns.rules[1].rule_set="discord"|.dns.rules[1].__service_tag="fakeip-dns-rule-tag"' "$work/input" > "$work/scalar"
dns_apply_patch_json "$work/scalar" "$work/pair" "$work/scalar.out"
jq -e '.dns.rules[1].rule_set=="discord" and (.dns.rules[1]|has("domain")|not) and .dns.rules[2].domain=="fakeip.podkop.fyi" and .dns.rules[2].__service_tag=="fakeip-service-dns-rule-tag"' "$work/scalar.out" >/dev/null
echo 'PASS: saved mixed FakeIP migration, preserved graph, idempotence and scalar tags'
