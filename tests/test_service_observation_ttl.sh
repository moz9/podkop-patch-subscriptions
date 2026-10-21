#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-checks.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
subscription_services_classify chatgpt 28 000 '' | jq -e '.state=="unknown" and .network=="fail"' >/dev/null || fail 'timeout is not proof of unusable node'
subscription_services_classify chatgpt 0 503 '' | jq -e '.state=="unknown"' >/dev/null || fail 'service outage became node denial'
subscription_services_classify chatgpt 0 403 '{"error":{"code":"unsupported_country"}}' | jq -e '.state=="fail" and .reason=="region_denied"' >/dev/null || fail 'explicit denial lost'
PODKOP_SERVICE_CACHE_DIR="$work/cache"
subscription_services_context() { echo stable; }
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_link_id() { [ "${#1}" = 32 ]; }
subscription_services_mark_pending() { :; }
date() { if [ "$*" = +%s ]; then echo "$now"; else command date "$@"; fi; }
now=100000
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
subscription_services_store main "$id" '{"gemini":{"state":"pass","reason":"region_precheck_passed"},"chatgpt":{"state":"fail","reason":"region_denied"}}'
path="$(subscription_services_cache_slot "$(subscription_services_context main)" "$id")"
jq -e '.results[0].services.gemini.expiresAt==186400 and .results[0].services.chatgpt.expiresAt==100300' "$path" >/dev/null || fail 'negative cached for a day'
now=100299
subscription_services_read main | jq -e '.[0].services.chatgpt.state=="fail"' >/dev/null || fail 'fresh denial missing'
now=100300
subscription_services_read main | jq -e '.[0].services.gemini.state=="pass" and (.[0].services|has("chatgpt")|not)' >/dev/null || fail 'expired negative survived'
now=100400
subscription_services_store main "$id" '{"chatgpt":{"state":"unknown","reason":"challenge_required"}}'
jq -e '.results[0].services.chatgpt.expiresAt==101300 and .results[0].services.gemini.expiresAt==186400' "$path" >/dev/null || fail 'CAPTCHA TTL or unrelated observation changed'
now=101300
subscription_services_read main | jq -e '.[0].services|has("chatgpt")|not' >/dev/null || fail 'expired CAPTCHA survived'
now=100399
subscription_services_read main | jq -e '.==[]' >/dev/null || fail 'future observation accepted after clock rollback'
echo 'PASS: unknown transport/outage results; per-service 24h/5m/15m TTL without renewing other observations'
