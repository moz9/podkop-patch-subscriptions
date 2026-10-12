#!/bin/sh
set -eu
# Explicit compatibility fixture for the former split worker architecture.
export PODKOP_SECTION_MODE=split
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test -f "$root/openwrt/podkop-section-hooks.sh" || { echo 'FAIL: isolated runtime hooks missing'; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
PODKOP_SECTION_ROOT=$tmp/state
mkdir -p "$PODKOP_SECTION_ROOT"
export PODKOP_SECTION_ROOT
config_get() { eval "$1=main"; }
ubus() { printf '%s\n' '{"values":{"settings":{".type":"settings"},"main":{".type":"section"},"GEOBLOCK":{".type":"section"}}}'; }
uci() { case "$*" in '-q changes podkop') printf '%s' "${pending:-}";; '-q show podkop') printf '%s\n' 'podkop.main=section' 'podkop.GEOBLOCK=section';; esac; }
. "$root/openwrt/podkop-section-hooks.sh"
podkop_section_context_hash > "$PODKOP_SECTION_ROOT/context.sha256"
podkop_section_ready() { return 0; }
podkop_section_resource_preflight() { return 0; }
podkop_section_preflight '{"sections":[{"section":"main","changes":[]}]}'
test "$PODKOP_SECTION_TARGET" = main || { echo 'FAIL: split apply target not retained for per-section pending clear'; exit 1; }
if podkop_section_preflight '{"sections":[{"section":"main"},{"section":"GEOBLOCK"}]}'; then echo 'FAIL: multi-section apply accepted'; exit 1; fi
test "$PODKOP_SECTION_ERROR" = isolated_section_only
pending='podkop.GEOBLOCK.foo=bar'
if podkop_section_preflight '{"sections":[{"section":"main"}]}'; then echo 'FAIL: foreign UCI draft accepted'; exit 1; fi
test "$PODKOP_SECTION_ERROR" = uci_pending_changes
pending=''
printf 'wrong\n' > "$PODKOP_SECTION_ROOT/context.sha256"
podkop_section_preflight '{"sections":[{"section":"main"}]}' || { echo 'FAIL: unrelated saved settings blocked section-only apply'; exit 1; }
test "$(cat "$PODKOP_SECTION_ROOT/context.sha256")" = wrong || { echo 'FAIL: global context marker was blessed'; exit 1; }
podkop_section_context_hash > "$PODKOP_SECTION_ROOT/context.sha256"
podkop_section_ready() { return 1; }
if podkop_section_preflight '{"sections":[{"section":"main"}]}'; then echo 'FAIL: unavailable isolated worker accepted'; exit 1; fi
test "$PODKOP_SECTION_ERROR" = section_isolation_unavailable
# Actual candidate construction must preserve the other section and routing.
printf '%s\n' '{"outbounds":[{"tag":"main-1-out","type":"old"},{"tag":"main-out","type":"selector"},{"tag":"GEOBLOCK-out","type":"vless","server":"untouched.invalid"}],"route":{"final":"GEOBLOCK-out"}}' > "$PODKOP_SECTION_ROOT/logical.json"
configure_outbound_handler() { config=$(printf '%s' "$config" | jq '.outbounds += [{tag:"main-2-out",type:"new"},{tag:"main-out",type:"selector"}]'); }
podkop_section_candidate "$tmp/candidate.json"
jq -e '.route.final=="GEOBLOCK-out" and ([.outbounds[]|select(.tag=="GEOBLOCK-out")][0].server=="untouched.invalid") and any(.outbounds[];.tag=="main-2-out") and (any(.outbounds[];.tag=="main-1-out")|not)' "$tmp/candidate.json" >/dev/null
printf '{"inbounds":[]}\n' > "$tmp/frontend.json"
printf '{"outbounds":[]}\n' > "$PODKOP_SECTION_ROOT/worker.json"
first=$(podkop_section_runtime_hash "$tmp/frontend.json")
printf '{"outbounds":[{"tag":"changed"}]}\n' > "$PODKOP_SECTION_ROOT/worker.json"
second=$(podkop_section_runtime_hash "$tmp/frontend.json")
test "$first" != "$second" || { echo 'FAIL: snapshot ignores changed worker'; exit 1; }
echo 'section runtime hooks: PASS'
