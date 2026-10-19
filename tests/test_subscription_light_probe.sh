#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo/openwrt/podkop-subscription-probe.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
input='{"dns":{"servers":[{"type":"https","tag":"dns","server":"dns.example","detour":"dns-pool"}],"rules":[{"rule_set":["dns-list"],"server":"dns"}],"final":"dns"},"outbounds":[{"tag":"candidate","type":"vless","server":"candidate.example","detour":"transport"},{"tag":"transport","type":"shadowtls","detour":"direct"},{"tag":"direct","type":"direct"},{"tag":"dns-pool","type":"urltest","outbounds":["dns-node"]},{"tag":"dns-node","type":"socks","detour":"direct"},{"tag":"list-download","type":"direct"},{"tag":"unused-pool","type":"urltest","outbounds":["unused-node"]},{"tag":"unused-node","type":"direct"}],"route":{"rule_set":[{"type":"remote","tag":"dns-list","url":"https://list.example/dns.srs","download_detour":"list-download"},{"type":"remote","tag":"unused-list","url":"https://list.example/unused.srs"}],"rules":[{"outbound":"unused-pool"}],"default_domain_resolver":"dns"}}'
subscription_probe_config "$input" candidate 43123 > "$tmp/graph"
jq -e '(.outbounds|map(.tag)|sort)==["candidate","direct","dns-node","dns-pool","list-download","transport"] and .outbounds[3].type=="selector" and .outbounds[3].default=="dns-node" and (.route.rule_set|map(.tag))==["dns-list"] and .dns.final=="dns"' "$tmp/graph" >/dev/null || fail 'unrelated pools retained or transitive DNS/candidate dependency lost'
broken="$(printf '%s' "$input" | jq '.outbounds[1].detour="missing"')"
if subscription_probe_config "$broken" candidate 43123 > /dev/null 2>&1; then fail 'missing reachable dependency accepted'; fi
duplicate="$(printf '%s' "$input" | jq '.outbounds += [.outbounds[0]]')"
if subscription_probe_config "$duplicate" candidate 43123 >/dev/null 2>&1; then fail 'duplicate tags accepted'; fi
cycle="$(printf '%s' "$input" | jq '.outbounds[2].detour="transport"')"
subscription_probe_config "$cycle" candidate 43123 >/dev/null || fail 'dependency cycle caused nontermination'
PODKOP_SUBSCRIPTION_MEMINFO_FILE="$tmp/meminfo"
export PODKOP_SUBSCRIPTION_MEMINFO_FILE
printf 'MemTotal: 131072 kB\nMemAvailable: 65536 kB\n' > "$tmp/meminfo"
subscription_probe_resources speed 8 || fail 'valid low RAM admission rejected'
[ "$SUBSCRIPTION_PROBE_STREAMS" = 2 ] || fail 'low RAM speed streams not bounded to 2'
[ "$SUBSCRIPTION_PROBE_REQUIRED_KB" = 36864 ] || fail 'curl RAM reserve not accounted'
printf 'MemTotal: 524288 kB\nMemAvailable: 65536 kB\n' > "$tmp/meminfo"
subscription_probe_resources speed 8 || fail 'large RAM admission rejected'
[ "$SUBSCRIPTION_PROBE_STREAMS" = 8 ] || fail 'configured parallel speed semantics changed on large RAM'
printf 'MemTotal: 131072 kB\nMemAvailable: 32767 kB\n' > "$tmp/meminfo"
if subscription_probe_resources services 1; then fail 'low memory admitted'; fi
[ "$SUBSCRIPTION_PROBE_ERROR" = insufficient_memory ] || fail 'low memory error lost'
printf 'MemTotal: 131072 kB\n' > "$tmp/meminfo"
if subscription_probe_resources ping 1; then fail 'unknown memory admitted'; fi
[ "$SUBSCRIPTION_PROBE_ERROR" = memory_unavailable ] || fail 'unknown memory error lost'
echo 'PASS: minimal transitive probe graph, fail-closed RAM admission and low-RAM speed concurrency'
