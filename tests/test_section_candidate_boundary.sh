#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
. "$repo/openwrt/podkop-section-hooks.sh"
podkop_section_root() { printf '%s' "$work"; }
podkop_section_name() { printf main; }
PODKOP_SECTION_TARGET=main
printf '%s\n' '{"dns":{"final":"active-dns"},"route":{"final":"GEOBLOCK-out"},"outbounds":[{"tag":"main-1-out","type":"old"},{"tag":"main-out","type":"selector"},{"tag":"GEOBLOCK-out","type":"socks","server":"peer.invalid"}]}' > "$work/logical.json"
configure_outbound_handler() { config="$(printf '%s' "$config" | jq '.outbounds += [{tag:"main-2-out",type:"socks"},{tag:"main-out",type:"selector"}]')"; }
podkop_section_candidate "$work/candidate" || { echo 'FAIL: target-only update rejected'; exit 1; }
configure_outbound_handler() { config="$(printf '%s' "$config" | jq '.dns.final="saved-but-not-applied" | .outbounds += [{tag:"main-out",type:"selector"}]')"; }
if podkop_section_candidate "$work/candidate"; then echo 'FAIL: candidate changed active DNS'; exit 1; fi
configure_outbound_handler() { config="$(printf '%s' "$config" | jq '.outbounds |= map(if .tag=="GEOBLOCK-out" then .server="changed.invalid" else . end)')"; }
if podkop_section_candidate "$work/candidate"; then echo 'FAIL: candidate changed peer worker'; exit 1; fi
configure_outbound_handler() { config="$(printf '%s' "$config" | jq '.route.final="main-out"')"; }
if podkop_section_candidate "$work/candidate"; then echo 'FAIL: candidate changed global routing'; exit 1; fi
echo 'PASS: isolated candidate preserves active DNS, route, and peer outbounds'
