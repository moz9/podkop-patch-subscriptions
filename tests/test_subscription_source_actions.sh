#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-subscription-sources.sh"
source_action_runtime="$repo/openwrt/runtime-0.7.23/usr/bin/podkop"
[ -f "$source_action_runtime" ] || source_action_runtime="$repo/openwrt/runtime-0.7.20/usr/bin/podkop"
source_action_functions='refresh_subscription_cache subscription_update_section_handler subscription_update subscription_update_json'
if [ "$(jq -r '.releaseStatus // "released"' "$repo/openwrt/update-manifest.json")" = prepared ]; then
    source_action_runtime="$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
    source_action_functions="$source_action_functions subscription_pending_sections_json subscription_pending_mark"
fi
for name in $source_action_functions; do
    sed -n "/^$name() {$/,/^}$/p" "$source_action_runtime" >> "$work/functions"
done
. "$work/functions"
get_subscription_link_id() { printf '%s' "$1" | md5sum | cut -d ' ' -f 1; }
get_subscription_cache_path() { echo "$work/$1.links"; }
get_subscription_all_cache_path() { echo "$work/$1.all"; }
get_subscription_items_cache_path() { echo "$work/$1.items"; }
get_subscription_skipped_cache_path() { echo "$work/$1.skipped"; }
collect_subscription_urls() { printf '%s\n' https://one.example/sub https://two.example/sub > "$2"; }
collect_subscription_excluded_ids() { : > "$2"; }
get_service_proxy_address() { :; }
subscription_disabled_sources_json() { printf '["%s"]\n' "$one"; }
log() { :; }
echolog() { :; }
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { [ "$1" = main ]; }
config_get() { case "$3" in connection_type) eval "$1=proxy";; proxy_config_type) eval "$1=subscription_urltest";; subscription_disabled_source_ids) eval "$1=\$one";; esac; }
config_list_foreach() { :; } # This fixture has no configured tag lists.
section_has_subscription_urls() { return 0; }
config_foreach() { "$1" main; }
subscription_runtime_busy() { [ "${busy:-0}" -eq 1 ]; }
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { :; }
subscription_reload_pending_file() { echo "$work/pending"; }
subscription_reload_seamless() { echo reload >> "$work/reloads"; }
download_subscription_to_file() {
    printf '%s\n' "$1" >> "$work/downloads"
    [ "${download_fail:-0}" -eq 0 ] || return 1
    [ "${failed_url:-}" != "$1" ] || return 1
    printf '%s\n' "${download_link:-new}" shared > "$2"
}
normalize_subscription_file() { [ "${invalid_format:-0}" -eq 0 ] && cp "$1" "$2"; }
filter_working_subscription_proxy_links() {
    cp "$2" "$3"; cp "$2" "$4"; : > "$5"; : > "$6"
    while IFS= read -r link; do
        jq -cn --arg id "$(get_subscription_link_id "$link")" --arg sid "$one" '{id:$id,supported:true,enabled:true,sourceIds:[$sid],sourceIndex:1}' >> "$6"
    done < "$2"
}
SUBSCRIPTION_CACHE_DIR="$work"
one="$(get_subscription_link_id https://one.example/sub)"
two="$(get_subscription_link_id https://two.example/sub)"
old="$(get_subscription_link_id old)"; shared="$(get_subscription_link_id shared)"; other="$(get_subscription_link_id other)"
jq -cn --arg one "$one" --arg two "$two" --arg old "$old" --arg shared "$shared" --arg other "$other" '[
 {id:$old,supported:true,enabled:true,sourceIds:[$one],sourceIndex:1},
 {id:$shared,supported:true,enabled:true,sourceIds:[$one,$two],sourceIndex:1},
 {id:$other,supported:true,enabled:true,sourceIds:[$two],sourceIndex:2}]' > "$work/main.items"
printf '%s\n' old shared other > "$work/main.all"
printf '%s\n' shared other > "$work/main.links"
printf '[]\n' > "$work/main.skipped"
printf '{"%s":"download_failed"}\n' "$two" > "$work/main.items.refresh-errors"
subscription_update_json main "$one" | jq -e '.success' >/dev/null
if [ "$(jq -r '.releaseStatus // "released"' "$repo/openwrt/update-manifest.json")" = prepared ]; then
    # This source is disabled: metadata changes do not change the effective links.
    [ ! -f "$work/pending" ] || { echo 'FAIL: disabled source with unchanged active links marked activation pending'; exit 1; }
fi
[ "$(cat "$work/downloads")" = https://one.example/sub ] || { echo 'FAIL: single source action downloads other subscriptions'; exit 1; }
jq -e --arg old "$old" --arg other "$other" --arg shared "$shared" 'all(.[]; .id!=$old) and any(.[];.id==$other) and any(.[];.id==$shared and (.sourceIds|length)==2)' "$work/main.items" >/dev/null
jq -e --arg two "$two" '.[$two]=="download_failed"' "$work/main.items.refresh-errors" >/dev/null
[ "$(cat "$work/main.links")" = "$(printf 'shared\nother')" ]
[ ! -e "$work/reloads" ] || { echo 'FAIL: disabled source refresh reloads production'; exit 1; }
before="$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all")"
download_fail=1
subscription_update_json main "$one" | jq -e '.success==false' >/dev/null
[ "$before" = "$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all")" ]
download_fail=0; invalid_format=1
subscription_update_json main "$one" | jq -e '.success==false' >/dev/null
[ "$before" = "$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all")" ]
subscription_update_json main invalid | jq -e '.success==false' >/dev/null
invalid_format=0; failed_url=https://two.example/sub
# A failed peer must retain its old nodes while the successful source can refresh.
subscription_update_json '' | jq -e '.success==true' >/dev/null || { echo 'FAIL: healthy subscription blocked by a failed peer'; exit 1; }
jq -e --arg other "$other" 'any(.[];.id==$other)' "$work/main.items" >/dev/null
jq -e --arg two "$two" '.[$two]=="download_failed"' "$work/main.items.refresh-errors" >/dev/null
failed_url=''; download_link=brandnew
subscription_services_policy() { printf '{"required":["gemini"],"results":[]}\n'; }
working_before="$(sha256sum "$work/main.links")"
subscription_update_json main "$one" | jq -e '.success==true' >/dev/null || { echo 'FAIL: stale service evidence blocks a read-only catalog refresh'; exit 1; }
[ "$(sha256sum "$work/main.links")" = "$working_before" ] || { echo 'FAIL: unadmitted refreshed catalog replaced the retained working links'; exit 1; }
brandnew="$(get_subscription_link_id brandnew)"
jq -e --arg id "$brandnew" 'any(.[];.id==$id) and all(.[];.runtimeEnabled==false)' "$work/main.items" >/dev/null || { echo 'FAIL: refreshed catalog or fail-closed service preview missing'; exit 1; }
busy=1
subscription_update_json main "$one" | jq -e '.success==false' >/dev/null
subscription_update_json '' | jq -e '.success==false and .error=="service_busy" and .retryAfter>0' >/dev/null || { echo 'FAIL: global busy update must not report success'; exit 1; }
echo 'PASS: scoped refresh downloads only its source, preserves peers and shared links, and retains cache on errors'
