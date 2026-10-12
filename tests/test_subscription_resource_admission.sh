#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-subscription-sources.sh"
runtime="${PODKOP_TEST_RUNTIME:-$repo/openwrt/runtime-0.7.22/usr/bin/podkop}"
for name in refresh_subscription_cache subscription_update_section_handler subscription_update subscription_update_json normalize_subscription_file extract_subscription_proxy_links; do
    sed -n "/^$name() {$/,/^}$/p" "$runtime" >> "$work/functions"
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

fail() { echo "FAIL: $*" >&2; exit 1; }
eval "$(sed -n '/^normalize_subscription_file() {$/,/^}$/p' "$runtime")"
convert_crlf_to_lf() { sed -i 's/\r$//' "$1"; }
filter_working_subscription_proxy_links() { echo invoked > "$work/parser-called"; return 1; }
download_subscription_to_file() { echo invoked >> "$work/downloads"; cp "$work/provider" "$2"; }
echolog() { echo "$*"; }
PODKOP_SUBSCRIPTION_MEMINFO_FILE="$work/meminfo"
export PODKOP_SUBSCRIPTION_MEMINFO_FILE
printf 'MemAvailable: 262144 kB\n' > "$work/meminfo"
printf 'unchanged active engine\n' > "$work/active-config"
printf 'unchanged saved UCI\n' > "$work/uci-config"
before="$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all" "$work/main.skipped" "$work/active-config" "$work/uci-config")"
check_refused() {
    expected="$1"
    result="$(subscription_update_json main "$one")"
    printf '%s' "$result" | jq -e '.success==false' >/dev/null || fail 'resource failure reported success'
    jq -e --arg id "$one" --arg expected "$expected" '.[$id]==$expected' "$work/main.items.refresh-errors" >/dev/null || fail "wrong source error for $expected"
    [ "$before" = "$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all" "$work/main.skipped" "$work/active-config" "$work/uci-config")" ] || fail "changed previous cache/config for $expected"
    [ ! -e "$work/parser-called" ] || fail 'expensive parser was reached before admission'
    [ ! -e "$work/reloads" ] || fail 'resource refusal reloaded active runtime'
}
dd if=/dev/zero of="$work/provider" bs=1048577 count=1 2>/dev/null
check_refused subscription_too_large
awk 'BEGIN {for(i=1;i<=2049;i++) print "vless://node-" i}' > "$work/provider"
check_refused subscription_too_many_nodes
base64 "$work/provider" > "$work/encoded"; mv "$work/encoded" "$work/provider"
check_refused subscription_too_many_nodes
awk 'BEGIN {printf "vless://"; for(i=1;i<=16385;i++) printf "a"; print ""}' > "$work/provider"
check_refused subscription_link_too_large
printf '<html>provider unavailable</html>\n' > "$work/provider"
check_refused unsupported_format
# Refuse low or unknown memory before downloading, parsing or changing status.
rm -f "$work/downloads"
status_before="$(sha256sum "$work/main.items.refresh-errors")"
for mode in low unknown; do
    if [ "$mode" = low ]; then printf 'MemAvailable: 1 kB\n' > "$work/meminfo"; else printf 'MemFree: 262144 kB\n' > "$work/meminfo"; fi
    result="$(subscription_update_json main "$one")"
    printf '%s' "$result" | jq -e '.success==false and (.output|contains("subscription_"))' >/dev/null || fail 'missing actionable resource refusal'
    [ ! -e "$work/downloads" ] || fail 'download started before memory admission'
    [ "$status_before" = "$(sha256sum "$work/main.items.refresh-errors")" ] || fail 'preflight refusal rewrote status'
    [ "$before" = "$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all" "$work/main.skipped" "$work/active-config" "$work/uci-config")" ] || fail 'memory refusal changed state'
done
printf 'MemAvailable: 262144 kB\n' > "$work/meminfo"
subscription_resource_memory 1048576 2048 || fail 'ample-memory bounded candidate rejected'
# Preserve ordinary extraction semantics while removing pipeline ambiguity.
printf '%s\n' '["vless://first","ss://second"]' '>trojan://third' 'vless://first' > "$work/ordinary"
normalize_subscription_file "$work/ordinary" "$work/ordinary.links" || fail 'valid bounded source rejected'
[ "$(cat "$work/ordinary.links")" = "$(printf 'vless://first\nss://second\ntrojan://third')" ] || fail 'single-process extraction changed ordering/dedup'
# Compressed bodies are not decompressed implicitly; preserve cache on rejection.
printf '<html>not a subscription</html>\n' | gzip -c > "$work/provider"
check_refused unsupported_format
# A normalization subprocess that wrote a prefix then failed is not success.
eval "$(sed -n '/^extract_subscription_proxy_links() {$/,/^}$/p' "$runtime" | sed '1s/extract_subscription_proxy_links()/real_extract_subscription_proxy_links()/')"
extract_subscription_proxy_links() { printf 'vless://partial\n' > "$2"; return 1; }
printf 'vless://full\n' > "$work/provider"
check_refused subscription_parse_failed
extract_subscription_proxy_links() { real_extract_subscription_proxy_links "$@"; }
# Per-source limits cannot be multiplied by many sources before the total check.
PODKOP_SUBSCRIPTION_MAX_NODES=3
export PODKOP_SUBSCRIPTION_MAX_NODES
printf 'vless://a\nvless://b\n' > "$work/provider"
filter_working_subscription_proxy_links() {
    printf 'parse\n' >> "$work/parser-count"
    cp "$2" "$3"; cp "$2" "$4"; : > "$5"; : > "$6"
    while IFS= read -r link; do
        jq -cn --arg id "$(get_subscription_link_id "$link")" --arg sid "$(get_subscription_link_id "$subscription_url")" '{id:$id,supported:true,enabled:true,sourceIds:[$sid]}' >> "$6"
    done < "$2"
}
result="$(subscription_update_json main)"
printf '%s' "$result" | jq -e '.success==false' >/dev/null || fail 'per-source limit bypassed section total'
[ "$(wc -l < "$work/parser-count")" -eq 1 ] || fail 'over-budget second source reached parser'
[ "$before" = "$(sha256sum "$work/main.items" "$work/main.links" "$work/main.all" "$work/main.skipped" "$work/active-config" "$work/uci-config")" ] || fail 'aggregate refusal changed working data'
unset PODKOP_SUBSCRIPTION_MAX_NODES
# Overrides are bounded, decimal, and do not override low-memory admission.
for invalid in -1 0 abc 8193 99999999999999999999999999999999999; do
    PODKOP_SUBSCRIPTION_MAX_NODES="$invalid"
    if subscription_resource_limits; then fail "invalid node override accepted: $invalid"; fi
    [ "$SUBSCRIPTION_RESOURCE_ERROR" = subscription_resource_limits_invalid ] || fail 'bad override lost typed error'
done
PODKOP_SUBSCRIPTION_MAX_NODES=0008
PODKOP_SUBSCRIPTION_MAX_SOURCE_BYTES=01048576
subscription_resource_limits || fail 'bounded decimal leading-zero override rejected'
[ "$SUBSCRIPTION_RESOURCE_MAX_NODES" = 8 ] && [ "$SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES" = 1048576 ] || fail 'decimal override normalization wrong'
PODKOP_SUBSCRIPTION_MAX_SOURCE_BYTES=99999999999999999999999999999999999
if subscription_resource_limits; then fail 'overflowing byte override accepted'; fi
unset PODKOP_SUBSCRIPTION_MAX_SOURCE_BYTES PODKOP_SUBSCRIPTION_MAX_NODES
for invalid in 999999999999999999999 -1 08; do
    if subscription_resource_memory "$invalid" 0; then fail 'malformed byte counter accepted'; fi
done
printf 'MemAvailable: 999999999999999999999999 kB\n' > "$work/meminfo"
if subscription_resource_memory 0 0; then fail 'overflowing memory counter accepted'; fi
[ "$SUBSCRIPTION_RESOURCE_ERROR" = subscription_memory_unavailable ] || fail 'malformed memory lost typed error'
PODKOP_SUBSCRIPTION_MAX_NODES=8192
printf 'MemAvailable: 1 kB\n' > "$work/meminfo"
if subscription_resource_memory 1048576 2048; then fail 'override bypassed memory admission'; fi
unset PODKOP_SUBSCRIPTION_MAX_NODES
printf 'MemAvailable: 262144 kB\n' > "$work/meminfo"

# New helper and refresh/downloader checks must be delivered into native runtimes.
for native in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    grep -Fqx '# subscription_resource_admission_v1' "$native" || fail "helper missing from $native"
    sed -n '/^refresh_subscription_cache() {$/,/^}$/p' "$native" | grep -Fq 'subscription_resource_cache' || fail "admission missing from $native"
done
echo 'PASS: byte/node/line/decode/malformed guards and low/unknown RAM preserve complete cache, saved config and active runtime'
