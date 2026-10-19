#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo/openwrt/podkop-section-hooks.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
podkop_section_root() { echo "$work"; }
curl() { case "$*" in *'/delay?'*) echo '{"delay":180}';; *) echo '{"proxies":{"main-out":{"now":"main-urltest-out"},"main-urltest-out":{"now":"main-2-out"}}}';; esac; }
echo '{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}},"outbounds":[{"tag":"main-2-out","type":"vless","server":"good.example","uuid":"fixture-a"}]}' > "$work/logical.json"
echo '{"dns":{"final":"keep"},"outbounds":[{"tag":"main-1-out","type":"vless","server":"good.example","uuid":"fixture-a"},{"tag":"main-2-out","type":"vless","server":"different.example","uuid":"fixture-b"},{"tag":"main-urltest-out","type":"urltest","outbounds":["main-2-out","main-1-out"]},{"tag":"main-out","type":"selector","default":"main-urltest-out","outbounds":["main-urltest-out","main-1-out"]}]}' > "$work/candidate.json"
command -v podkop_section_prefer_live_candidate >/dev/null || { echo 'FAIL: known live startup choice is not preserved'; exit 1; }
podkop_section_prefer_live_candidate "$work/candidate.json" main
jq -e '.outbounds[]|select(.tag=="main-urltest-out")|.outbounds==["main-1-out","main-2-out"]' "$work/candidate.json" >/dev/null
jq -e '.dns.final=="keep" and ([.outbounds[]|select(.tag=="main-out")][0].default=="main-urltest-out")' "$work/candidate.json" >/dev/null
cp "$work/candidate.json" "$work/before"
curl() { echo '{"delay":0}'; }
podkop_section_prefer_live_candidate "$work/candidate.json" main
cmp "$work/candidate.json" "$work/before"
echo 'PASS: startup ordering uses exact node identity, preserves auto mode and skips unknown health'
