#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_APPLY_LIBRARY_ONLY=1
. "$repo/openwrt/podkop-dns-apply"
dns_reserve_saved_uci() { [ "$2" = export_json ] || return 1; cat "$1"; }
printf '%s\n' "package podkop" "config settings 'settings'" " option dns_type 'udp'" " option note 'literal \$(touch $tmp/must-not-run)'" " list future_policy 'with spaces'" " list future_policy 'second'" "config section 'main'" " option enable_udp_over_tcp '0'" > "$tmp/committed"
command -v dns_reserve_saved_uci_json >/dev/null 2>&1 || fail 'committed UCI JSON adapter missing'
dns_reserve_saved_uci_json "$tmp/committed" > "$tmp/json" || fail 'saved JSON construction failed'
jq -e --arg note "literal \$(touch $tmp/must-not-run)" '.values=={settings:{".anonymous":false,".name":"settings",".index":0,".type":"settings",dns_type:"udp",note:$note,future_policy:["with spaces","second"]},main:{".anonymous":false,".name":"main",".index":1,".type":"section",enable_udp_over_tcp:"0"}}' "$tmp/json" >/dev/null || fail 'unknown values, list order or section metadata changed'
[ ! -e "$tmp/must-not-run" ] || fail 'literal UCI value executed'
printf '%s\n' 'package podkop' 'config section' " option value 'anonymous'" > "$tmp/anonymous"
if dns_reserve_saved_uci_json "$tmp/anonymous" >/dev/null 2>&1; then fail 'anonymous identity guessed'; fi
printf '%s\n' 'package podkop' "config section 'main'" "config section 'main'" > "$tmp/duplicate"
if dns_reserve_saved_uci_json "$tmp/duplicate" >/dev/null 2>&1; then fail 'duplicate section identity accepted'; fi
printf '%s\n' 'package podkop' " option value 'before-section'" > "$tmp/orphan"
if dns_reserve_saved_uci_json "$tmp/orphan" >/dev/null 2>&1; then fail 'orphan option accepted'; fi
echo 'PASS: committed UCI adapter preserves metadata, values/list order and rejects ambiguous section identities'
