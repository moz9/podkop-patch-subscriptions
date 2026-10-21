#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
admission_fixture="$(mktemp -d)"
trap 'rm -rf "$admission_fixture"' EXIT HUP INT TERM
version=0.7.24
[ -f "$repo/openwrt/runtime-$version/usr/bin/podkop" ] || version=0.7.22
sed -n '/^apply_subscription_exclusions_to_cached_links() {/,/^}/p' "$repo/openwrt/runtime-$version/usr/bin/podkop" > "$admission_fixture/functions"
. "$admission_fixture/functions"
get_subscription_cache_path() { printf '%s/cache' "$admission_fixture"; }
get_subscription_all_cache_path() { printf '%s/all' "$admission_fixture"; }
get_subscription_items_cache_path() { printf '%s/items' "$admission_fixture"; }
subscription_items_with_sources() { cat "$admission_fixture/items"; }
collect_subscription_excluded_ids() { : > "$2"; }
subscription_disabled_sources_json() { printf '[]'; }
subscription_filter_source_links() { : > "$3"; }
subscription_services_policy() { printf '%s' "$policy"; }
printf 'proxy\n' > "$admission_fixture/all"
printf '[{"id":"a","serviceExcluded":true}]\n' > "$admission_fixture/items"
policy='{"required":["gemini"],"results":[]}'
! apply_subscription_exclusions_to_cached_links main
[ "${SUBSCRIPTION_CACHE_ERROR:-unset}" = service_results_stale_or_missing ] || { echo 'FAIL: stale/missing proof reported as generic cache/reload failure'; exit 1; }
policy='{"required":["gemini"],"results":[{"id":"a","services":{"gemini":{"state":"fail"}}}]}'
! apply_subscription_exclusions_to_cached_links main
[ "$SUBSCRIPTION_CACHE_ERROR" = service_no_eligible_nodes ] || { echo 'FAIL: no eligible proof reported generically'; exit 1; }
echo 'PASS: empty service admission is distinguished from reload/cache failure'
