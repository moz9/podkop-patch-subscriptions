#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
. "$repo/openwrt/podkop-service-checks.sh"
. "$repo/openwrt/podkop-service-snapshot.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
fixture_manual_link='vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443#KZ-Manual'
collect_urltest_proxy_links() { printf '%s\n' "$fixture_manual_link" > "$2"; }
get_subscription_link_id() { case "$1" in subscription-link) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;; *KZ-Manual) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;; *) echo cccccccccccccccccccccccccccccccc;; esac; }
get_subscription_link_name() { printf '%s\n' "${1#*#}"; }
get_subscription_cache_path() { echo "$tmp/active"; }
get_subscription_all_cache_path() { echo "$tmp/all"; }
get_subscription_items_cache_path() { echo "$tmp/items"; }
printf 'subscription-link\n' > "$tmp/all"; cp "$tmp/all" "$tmp/active"
printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":true,"name":"US-Subscription"}]\n' > "$tmp/items"
subscription_services_context() { echo exact-context; }
subscription_required_services_json() { echo '["exit_country"]'; }
subscription_services_read() { cat "$tmp/evidence"; }
subscription_services_cache_raw() { jq '{results:.}' "$tmp/evidence"; }
validate_subscription_urltest_section() { return 0; }
printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","services":{"exit_country":{"state":"pass"}}}]\n' > "$tmp/evidence"
if ! link=$(subscription_services_manual_link main bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb); then fail 'manual service probe cannot resolve its exact saved URI'; fi
[ "$link" = "$fixture_manual_link" ] || fail 'manual lookup substituted another node'
[ "$(subscription_services_candidate_name main bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" = KZ-Manual ] || fail 'manual name unavailable for country proof'
! subscription_services_manual_ready main '["exit_country"]' || fail 'unmeasured manual node admitted'
jq '.+[{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",services:{exit_country:{state:"pass",declaredName:"KZ-Manual"}}}]' "$tmp/evidence" > "$tmp/next"; mv "$tmp/next" "$tmp/evidence"
subscription_services_manual_ready main '["exit_country"]' || fail 'measured manual node blocked by subscription-only restriction'
SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=0
subscription_filter_source_links() { printf 'subscription-link\n' > "$3"; }
subscription_disabled_sources_json() { echo '[]'; }
subscription_services_preflight_section main
[ "$SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED" = 0 ] || fail 'manual mix still rejected before service stop'
SNAPSHOT_CAPTURE=1; SNAPSHOT_FAILED=0; SNAPSHOT_SECTIONS="$tmp/sections"
subscription_services_snapshot_section main
[ "$SNAPSHOT_FAILED" = 0 ] || fail 'manual admission cannot be frozen'
jq -e '.admittedIds==["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] and (.evidence|map(.id)|sort)==.admittedIds and (.admittedLinks|length)==2' "$tmp/sections" >/dev/null || fail 'manual ID/link/evidence omitted from snapshot'
jq '.[1].services.exit_country.state="fail"' "$tmp/evidence" > "$tmp/next"; mv "$tmp/next" "$tmp/evidence"
! subscription_services_manual_ready main '["exit_country"]' || fail 'manual explicit denial ignored'
fixture_manual_link="${fixture_manual_link}-Changed"
! subscription_services_manual_ready main '["exit_country"]' || fail 'new URI reused old manual proof'
echo 'PASS: manual nodes resolve exactly, require service proof and join frozen admission; missing/denied/changed nodes fail closed'
