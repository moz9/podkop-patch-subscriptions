#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
. "$repo/openwrt/podkop-section-hooks.sh"
podkop_section_root() { printf '%s' "$work"; }
printf 'single\n' > "$work/runtime-mode"
printf '%s\n' '{"mode":"single","section":"main","version":3,"sections":[{"section":"main","api_port":9090},{"section":"GEOBLOCK","api_port":9090}]}' > "$work/metadata.json"
printf '%s\n' '{"dns":{"final":"active-dns"},"route":{"final":"direct-out"},"outbounds":[{"tag":"main-out","type":"selector","outbounds":["main-1-out"]},{"tag":"main-1-out","type":"direct"},{"tag":"GEOBLOCK-out","type":"selector","outbounds":["GEOBLOCK-1-out"]},{"tag":"GEOBLOCK-1-out","type":"direct"}]}' > "$work/logical.json"
config_get() {
    case "$3" in subscription_isolated_section) value=main;; connection_type) value=proxy;; proxy_config_type) value=subscription_urltest;; *) value="";; esac
    eval "$1=\$value"
}
uci() { return 0; }
podkop_section_manager() {
    case "$1" in
    status) printf '%s\n' '{"ready":true,"sections":[{"section":"main","ready":true},{"section":"GEOBLOCK","ready":true}]}';;
    preflight) return 0;;
    *) return 1;;
    esac
}
podkop_section_names | jq -e '.==["main","GEOBLOCK"]' >/dev/null
podkop_section_preflight '{"sections":[{"section":"GEOBLOCK"}]}' || { echo 'FAIL: GEOBLOCK single preflight'; exit 1; }
configure_outbound_handler() {
    config="$(printf '%s' "$config" | jq --arg s "$1" '.outbounds += [{tag:($s+"-out"),type:"selector",outbounds:[($s+"-2-out")]},{tag:($s+"-2-out"),type:"direct"}]')"
}
podkop_section_candidate "$work/candidate.json" || { echo 'FAIL: GEOBLOCK scoped candidate'; exit 1; }
jq -e --slurpfile old "$work/logical.json" '([.outbounds[]|select(.tag|startswith("main-"))]==[$old[0].outbounds[]|select(.tag|startswith("main-"))]) and .dns==$old[0].dns and .route==$old[0].route and any(.outbounds[];.tag=="GEOBLOCK-2-out")' "$work/candidate.json" >/dev/null
podkop_section_runtime_hash "$work/candidate.json" >/dev/null || { echo 'FAIL: single hash requires worker graph'; exit 1; }
if podkop_section_api_url main-out >/dev/null; then echo 'FAIL: native API auth would be cleared'; exit 1; fi
if podkop_section_preflight '{"sections":[{"section":"unknown"}]}'; then echo 'FAIL: unregistered section admitted'; exit 1; fi
uci() { printf '%s\n' "podkop.settings.dns_server='saved-draft'"; }
if podkop_section_preflight '{"sections":[{"section":"main"}]}'; then echo 'FAIL: pending global draft applied'; exit 1; fi
echo 'PASS: multi-section single hooks preserve peers and native auth, reject unknown sections/drafts'
rm "$work/runtime-mode" "$work/metadata.json"
config_get() { eval "$1=''"; }
podkop_section_enabled || { echo 'FAIL: fresh install without old isolated UCI not enabled'; exit 1; }
echo 'PASS: fresh runtime defaults single without old isolated UCI'

