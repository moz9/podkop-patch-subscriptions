#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-service-checks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_SERVICE_CACHE_DIR="$work/cache"
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { [ "$1" = main ]; }
validate_subscription_link_id() { [ "$1" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]; }
fixture_context=route_a
subscription_services_context() { echo "$fixture_context"; }
subscription_services_mark_pending() { :; }
fixture_time=10000
date() { [ "$1" = +%s ]; echo "$fixture_time"; }
subscription_isolated_test() { echo probe >> "$work/probes"; echo '{"success":true,"fixture":"network"}'; }
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
subscription_services_store main "$id" '{"gemini":{"state":"unknown","reason":"challenge_required","category":"captcha","network":"pass"},"chatgpt":{"state":"pass","network":"pass"}}'
: > "$work/probes"
original="$(cat "$(subscription_services_cache_slot "$(subscription_services_context main)" "$id")")"
subscription_services_check main "$id" '["gemini","chatgpt"]' | jq -e '.success and .cached and .services.gemini.checkedAt==10000' >/dev/null || fail 'fresh observations relaunched a worker'
[ ! -s "$work/probes" ] || fail 'cache hit started private runtime'
[ "$original" = "$(cat "$(subscription_services_cache_slot "$(subscription_services_context main)" "$id")")" ] || fail 'cache hit renewed evidence'
fixture_time=10030
subscription_services_check main "$id" '["gemini"]' | jq -e '.cached' >/dev/null || fail 'CAPTCHA cooldown lost'
subscription_services_check main "$id" '["gemini","chatgpt"]' | jq -e '.fixture=="network"' >/dev/null || fail 'expired service cooldown reused'
fixture_time=10300
subscription_services_check main "$id" '["gemini"]' | jq -e '.fixture=="network"' >/dev/null || fail 'CAPTCHA cooldown never expired'
fixture_time=10001; fixture_context=route_b
subscription_services_check main "$id" '["gemini"]' | jq -e '.fixture=="network"' >/dev/null || fail 'different route reused evidence'
fixture_context=route_a; fixture_time=9999
subscription_services_check main "$id" '["gemini"]' | jq -e '.fixture=="network"' >/dev/null || fail 'clock rollback reused evidence'
echo 'PASS: short diagnostic cooldown avoids repeated workers without renewing or widening proof'
