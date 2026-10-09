#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo/openwrt/podkop-subscription-probe.sh"
input='{"dns":{"servers":[{"tag":"real","type":"https","server":"dns.example","detour":"dns-out"}],"rules":[{"domain":["dns.example"],"server":"real"}],"strategy":"prefer_ipv6"},"inbounds":[{"type":"tproxy","tag":"live"}],"outbounds":[{"type":"direct","tag":"dns-out"},{"type":"hysteria2","tag":"candidate-out","server":"node.example","tls":{"enabled":true,"server_name":"tls.example"}},{"type":"urltest","tag":"pool","outbounds":["candidate-out"],"interval":"1m"}],"route":{"rules":[{"domain":["dns.example"],"outbound":"dns-out"}],"default_domain_resolver":"real"},"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"},"cache_file":{"enabled":true}}}'
result="$(subscription_probe_config "$input" candidate-out 43123)"
printf '%s' "$result" | jq -e --argjson input "$input" '
    .dns==$input.dns and .route.default_domain_resolver==$input.route.default_domain_resolver
    and .route.rules[0]=={inbound:["probe-in"],outbound:"candidate-out"}
    and (.route.rules|length)==1 and .route.final=="candidate-out"
    and .route.default_mark==2097152 and .inbounds==[{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:43123}]
    and .outbounds[1]==$input.outbounds[1] and .outbounds[2].type=="selector"
    and .outbounds[2].default=="candidate-out" and (has("experimental")|not)' >/dev/null
if subscription_probe_config "$input" missing-out 43123 >/dev/null 2>&1; then
    printf 'FAIL: missing probe outbound accepted\n'; exit 1
fi
! grep -Fq 'sleep 0.25' "$repo/openwrt/podkop-subscription-probe.sh"
lists='{"dns":{"servers":[{"type":"udp","tag":"real"},{"type":"fakeip","tag":"fake"}],"rules":[{"rule_set":["huge-remote"],"server":"fake"},{"domain":["bootstrap.example"],"server":"real"}]},"outbounds":[{"type":"direct","tag":"candidate-out"}],"route":{"rules":[{"rule_set":["huge-remote"],"outbound":"candidate-out"}],"rule_set":[{"type":"remote","tag":"huge-remote","url":"https://unavailable.invalid/list.srs"}]}}'
subscription_probe_config "$lists" candidate-out 43123 | jq -e '
    .route.rule_set==[] and (.dns.rules|length)==1
    and .dns.rules[0].server=="real" and (.route.rules|length)==1' >/dev/null
printf 'PASS: isolated probes retain DNS context and only route their private listener\n'
