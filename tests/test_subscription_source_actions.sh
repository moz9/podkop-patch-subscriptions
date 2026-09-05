#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-subscription-sources.sh"
for name in refresh_subscription_cache subscription_update_section_handler subscription_update subscription_update_json; do
    sed -n "/^$name() {$/,/^}$/p" "$repo/openwrt/runtime-0.7.22/usr/bin/podkop" >> "$work/functions"
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
section_has_subscription_urls() { return 0; }
config_foreach() { "$1" main; "$1" other; }
subscription_runtime_busy() { [ "${busy:-0}" -eq 1 ]; }
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { :; }
subscription_reload_pending_file() { echo "$work/pending"; }
subscription_reload_seamless() { echo reload >> "$work/reloads"; }
download_subscription_to_file() {
    printf '%s\n' "$1" >> "$work/downloads"
    [ "${download_fail:-0}" -eq 0 ] || return 1
    printf '%s\n' new shared > "$2"
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
busy=1
subscription_update_json main "$one" | jq -e '.success==false' >/dev/null
echo 'PASS: scoped refresh downloads only its source, preserves peers and shared links, and retains cache on errors'
