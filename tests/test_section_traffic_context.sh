#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
. "$repo/openwrt/podkop-section-hooks.sh"
podkop_section_names() { printf '["main"]\n'; }
podkop_section_name() { printf main; }
ubus() { cat "$work/uci.json"; }
uci() { case "$*" in *changes*) return 0;; *) cat "$work/uci.txt";; esac; }
printf "podkop.settings=settings\npodkop.settings.dns_type='doh'\n" > "$work/uci.txt"
jq -n '{values:{settings:{".type":"settings",".index":0,dns_type:"doh",dns_server:"cloudflare-dns.com",bootstrap_dns_server:"77.88.8.8"},main:{".type":"section",".index":1,connection_type:"proxy",proxy_config_type:"subscription_urltest",subscription_include_tags:[]},other:{".type":"section",".index":2}}}' > "$work/uci.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
hash="$(podkop_section_context_hash)"
case "$hash" in v2:*) ;; *) fail 'context is not versioned';; esac
change() { jq "$1" "$work/uci.json" > "$work/next"; mv "$work/next" "$work/uci.json"; }
change '.values.settings.dns_optimizer_candidates=["8.8.8.8"] | .values.settings.secondary_dns_server="reserve.example" | .values.settings.enable_utls_fallback="0" | .values.main.subscription_include_tags=["US*"]'
[ "$(podkop_section_context_hash)" = "$hash" ] || fail 'diagnostics/inactive reserve/default/registered choices changed traffic context'
change '.values.settings.unknown_future_route="1"'
[ "$(podkop_section_context_hash)" != "$hash" ] || fail 'unknown settings drift was ignored'
change 'del(.values.settings.unknown_future_route) | .values.settings.dns_server="dns.google"'
[ "$(podkop_section_context_hash)" != "$hash" ] || fail 'primary DNS drift was ignored'
change '.values.settings.dns_server="cloudflare-dns.com" | .values.other.subscription_include_tags=["US*"]'
[ "$(podkop_section_context_hash)" != "$hash" ] || fail 'nonregistered section policy drift was ignored'
change 'del(.values.other.subscription_include_tags) | .values.settings.dns_failover_enabled="1"'
[ "$(podkop_section_context_hash)" != "$hash" ] || fail 'failover enablement drift was ignored'
change '.values.settings.secondary_dns_type="doh" | .values.settings.secondary_bootstrap_dns_server="8.8.8.8" | .values.settings.dns_failover_active_slot="secondary"'
active="$(podkop_section_context_hash)"
change '.values.settings.secondary_dns_server="other.example"'
[ "$(podkop_section_context_hash)" != "$active" ] || fail 'active reserve DNS drift was ignored'
echo 'PASS: versioned traffic context excludes diagnostics, retains unknown/active/shared drift'
podkop_section_enabled() { return 0; }
podkop_section_ready() { return 0; }
podkop_section_resource_preflight() { return 0; }
podkop_section_root() { printf '%s' "$work"; }
legacy="$(podkop_section_context_hash_legacy)"
printf '%s\n' "$legacy" > "$work/context.sha256"
payload='{"sections":[{"section":"main"}]}'
podkop_section_preflight "$payload" || fail 'exact legacy baseline was not accepted'
[ "$(cat "$work/context.sha256")" = "$legacy" ] || fail 'section preflight rewrote global context'
podkop_section_context_matches || fail 'network context gate rejected proven v2 baseline'
printf 'stale-legacy-hash\n' > "$work/context.sha256"
podkop_section_preflight "$payload" || fail 'unrelated saved global settings blocked isolated section apply'
! podkop_section_context_matches || fail 'network context gate accepted unproven baseline'
[ "$(cat "$work/context.sha256")" = stale-legacy-hash ] || fail 'stale legacy marker was overwritten'
ubus() { return 1; }
! podkop_section_context_hash || fail 'failed UCI read was accepted'
echo 'PASS: isolated apply leaves global marker untouched; lifecycle fails closed on stale context'
