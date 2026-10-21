#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-checks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
printf '{"dns":{"servers":[{"type":"udp","server":"1.1.1.1"}]}}\n' > "$work/runtime"
# Only the fixed router file and UCI transport are substituted; hashing and
# canonicalization execute the production code and real jq.
jq() { [ "$#" != 3 ] || [ "$3" != /etc/sing-box/config.json ] || { command jq "$1" "$2" "$work/runtime"; return; }; command jq "$@"; }
uci() { [ "$*" = '-q show podkop.settings' ] || return 1; cat "$work/settings"; }
fixture_udp=0
config_get() { eval "$1=\$fixture_udp"; }
printf "podkop.settings=podkop\npodkop.settings.dns_type='udp'\npodkop.settings.dns_server='1.1.1.1'\n" > "$work/settings"
original="$(subscription_services_context main)"
printf "podkop.settings.dns_optimizer_candidates='quad9'\npodkop.settings.dns_optimizer_protocols='dot'\n" >> "$work/settings"
[ "$(subscription_services_context main)" = "$original" ] || fail 'candidate picker invalidated service observations'
printf "podkop.settings.dns_server='9.9.9.9'\n" >> "$work/settings"
[ "$(subscription_services_context main)" != "$original" ] || fail 'desired DNS change reused evidence'
printf "podkop.settings=podkop\npodkop.settings.dns_type='udp'\npodkop.settings.dns_server='1.1.1.1'\n" > "$work/settings"
fixture_udp=1
[ "$(subscription_services_context main)" != "$original" ] || fail 'UDP transport change reused evidence'
fixture_udp=0
printf "podkop.settings.future_routing_option='1'\n" >> "$work/settings"
[ "$(subscription_services_context main)" != "$original" ] || fail 'unknown traffic option silently excluded'
echo 'PASS: diagnostic-only edits reuse observations; DNS, transport and unknown routing edits invalidate'
