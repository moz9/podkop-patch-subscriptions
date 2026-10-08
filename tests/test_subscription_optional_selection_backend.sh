#!/bin/sh
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ -z "${PODKOP_OPTIONAL_TEST_RUNTIME:-}" ]; then
    for version in 0.7.20 0.7.22; do
        PODKOP_OPTIONAL_TEST_RUNTIME="$repo/openwrt/runtime-$version/usr/bin/podkop" sh "$0"
    done
    exit 0
fi
runtime="${PODKOP_OPTIONAL_TEST_RUNTIME:-$repo/openwrt/runtime-0.7.22/usr/bin/podkop}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Use the installed PE functions, not the historical subscription helper.
sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$runtime" > "$work/backend"
sed -n '/^# subscription_apply_v2 begin$/,/^# subscription_apply_v2 end$/p' "$runtime" >> "$work/backend"
. "$work/backend"

PODKOP_CONFIG="$work/config"
printf '{"main":{}}\n' > "$PODKOP_CONFIG"
config_get() {
    value="$(jq -r --arg s "$2" --arg k "$3" '.[$s][$k] // "" | if type=="array" then join(" ") else . end' "$PODKOP_CONFIG")"
    eval "$1=\$value"
}
config_list_foreach() {
    jq -r --arg s "$1" --arg k "$2" '.[$s][$k] // [] | .[]' "$PODKOP_CONFIG" > "$work/tags.list"
    while IFS= read -r value; do "$3" "$value"; done < "$work/tags.list"
}
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { :; }
subscription_runtime_busy() { return 1; }
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { [ "$1" = main ]; }
get_subscription_items_cache_path() { printf '%s/missing.items\n' "$work"; }

[ "$(subscription_selection_mode main)" = auto ] || fail 'missing selection mode must default to auto'
printf '{"main":{"subscription_excluded_link_ids":["old"]}}\n' > "$PODKOP_CONFIG"
[ "$(subscription_selection_mode main)" = all ] || fail 'legacy exclusions must retain their effective all mode during upgrade'
printf '{"main":{"subscription_selection_mode":"auto","subscription_excluded_link_ids":["old"]}}\n' > "$PODKOP_CONFIG"
[ "$(subscription_selection_mode main)" = auto ] || fail 'explicit auto must ignore stored manual preferences'
result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"auto","changes":[]}]}')" || true
printf '%s\n' "$result" | jq -e '.error=="subscription_cache_missing"' >/dev/null || fail 'auto mode must be accepted by transaction validation'

printf '%s\n' '[{"id":"old","supported":true,"sourceIds":["active"],"name":"SE Stockholm"},{"id":"selected","supported":true,"sourceIds":["active"],"name":"🇸🇪 Stockholm"},{"id":"eu","supported":true,"sourceIds":["active"],"name":"EU Transit"},{"id":"lower","supported":true,"sourceIds":["active"],"name":"se lower"},{"id":"middle","supported":true,"sourceIds":["active"],"name":"Node SE Stockholm"},{"id":"sweden","supported":true,"sourceIds":["active"],"name":"🇸🇪 Sweden"}]' > "$work/items"
subscription_source_policy '[]' '["old"]' "$work/items" auto '["selected"]' '["@prefix:SE"]' '[]' \
 | jq -e '.[0].runtimeEnabled and .[1].runtimeEnabled and .[5].runtimeEnabled and all(.[2:5][]; .tagExcluded) and all(.[]; .enabled)' >/dev/null || fail 'auto must ignore node lists but honor uppercase country tag'
subscription_source_policy '["active"]' '["old"]' "$work/items" auto '["selected"]' '["@prefix:SE"]' '[]' \
 | jq -e 'all(.[]; .runtimeEnabled | not)' >/dev/null || fail 'auto must still honor source disables'
subscription_source_policy '[]' '[]' "$work/items" auto '[]' '["@prefix:EU"]' '[]' \
 | jq -e '.[2].runtimeEnabled and all(.[0:2][]; .tagExcluded)' >/dev/null || fail 'plain EU leading prefix must match'
subscription_source_policy '[]' '[]' "$work/items" auto '[]' '["*🇸🇪*"]' '[]' \
 | jq -e '.[0].runtimeEnabled and .[1].runtimeEnabled and .[5].runtimeEnabled and (.[4].runtimeEnabled | not)' >/dev/null || fail 'saved single-flag glob must also match leading plain code'
subscription_source_policy '[]' '[]' "$work/items" all '[]' '["@prefix:SE"]' '["@prefix:EU"]' \
 | jq -e '.[0].runtimeEnabled and (.[2].runtimeEnabled | not)' >/dev/null || fail 'explicit all must keep tag include/exclude intersection'
subscription_source_policy '[]' '[]' "$work/items" selected '["old"]' '["@prefix:SE"]' '[]' \
 | jq -e '.[0].runtimeEnabled and (.[1].runtimeEnabled | not)' >/dev/null || fail 'explicit selected must retain manual choice'
printf '%s\n' '[{"id":"space","name":"  SE Stockholm  ","supported":true},{"id":"tab","name":"\tSE Stockholm\t","supported":true},{"id":"nbsp","name":"\u00a0SE Stockholm\u00a0","supported":true},{"id":"boundary","name":"SE\u00a0Stockholm","supported":true}]' > "$work/spaced.items"
subscription_source_policy '[]' '[]' "$work/spaced.items" auto '[]' '["@prefix:SE"]' '[]' \
 | jq -e 'all(.[]; .runtimeEnabled)' >/dev/null || fail 'country prefixes must trim names exactly like the UI'

SUBSCRIPTION_APPLY_V2_TMP="$work"
printf 'auto\n' > "$work/selection.main.mode"
printf 'all\n' > "$work/selection.main.current-mode"
printf '["selected"]\n' > "$work/selection.main.ids"
uci() {
    [ "$1" != -q ] || shift
    case "$1" in
        set) printf '%s\n' "$2" >> "$work/uci-writes" ;;
        *) fail "unexpected UCI write: $*" ;;
    esac
}
subscription_selection_stage main
grep -Fxq 'podkop.main.subscription_selection_mode=auto' "$work/uci-writes" || fail 'auto mode was not staged'
[ "$(wc -l < "$work/uci-writes")" -eq 1 ] || fail 'auto transition must preserve node lists'

subscription_disabled_sources_json() { printf '[]\n'; }
subscription_items_with_sources() { cat "$2"; }
printf '%s\n' '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":true,"sourceIds":["active"]},{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","supported":true,"sourceIds":["active"]}]' > "$work/transition.items"
printf '{"main":{"subscription_selection_mode":"auto","subscription_selected_link_ids":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}}\n' > "$PODKOP_CONFIG"
subscription_selection_prepare main '{"selectionMode":"selected","changes":[]}' "$work/transition.items" '[]'
[ "$(cat "$work/selection.main.ids")" = '["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' ] || fail 'auto to selected must resume the saved manual allowlist'
printf '{"main":{"subscription_selection_mode":"auto"}}\n' > "$PODKOP_CONFIG"
subscription_selection_prepare main '{"selectionMode":"selected","changes":[]}' "$work/transition.items" '[]'
[ "$(jq 'length' "$work/selection.main.ids")" -eq 2 ] || fail 'first manual selection must seed the current auto pool'
printf '{"main":{"subscription_selection_mode":"all","subscription_include_tags":["NO MATCH"]}}\n' > "$PODKOP_CONFIG"
subscription_selection_prepare main '{"selectionMode":"selected","changes":[]}' "$work/transition.items" '[]'
[ "$(jq 'length' "$work/selection.main.ids")" -eq 2 ] || fail 'explicit all to selected seeding must retain its historical behavior'

# Both pre-existing selection installs and pre-prefix installs must receive the
# full source policy and transactional validation without upgrading base Podkop.
for marker in subscription_optional_selection_v1 subscription_tag_prefix_v1; do
    sed "/^# $marker$/d" "$runtime" > "$work/delivery"
    PODKOP_SOURCES_TARGET="$work/delivery" PODKOP_SOURCES_SOURCE="$runtime" \
        sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    for capability in subscription_optional_selection_v1 subscription_tag_prefix_v1; do
        grep -Fqx "# $capability" "$work/delivery" || fail "missing retrofit capability $capability"
    done
    sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$work/delivery" > "$work/delivered.sources"
    cmp -s "$work/delivered.sources" "$repo/openwrt/podkop-subscription-sources.sh" || fail 'retrofit did not refresh canonical source policy'
    sed -n '/^set_subscription_sections_enabled() {$/,/^}$/p' "$runtime" > "$work/canonical.transaction"
    sed -n '/^set_subscription_sections_enabled() {$/,/^}$/p' "$work/delivery" > "$work/delivered.transaction"
    cmp -s "$work/canonical.transaction" "$work/delivered.transaction" || fail 'retrofit did not refresh auto transaction validation'
    sh -n "$work/delivery"
    cp "$work/delivery" "$work/installed"
    PODKOP_SOURCES_TARGET="$work/delivery" PODKOP_SOURCES_SOURCE="$runtime" \
        sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    cmp -s "$work/delivery" "$work/installed" || fail 'optional selection retrofit is not idempotent'
done

printf '%s\n' 'PASS: legacy optional auto selection, source and tag policy, legacy flag compatibility, and preserved manual lists'
