#!/bin/sh
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo/openwrt/runtime-0.7.23/usr/bin/podkop"
lib="$repo/openwrt/runtime-0.7.23/usr/lib/podkop"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -s "$runtime" ] || fail '0.7.23 runtime is absent'
sh -n "$runtime" || fail 'runtime shell syntax'
for name in helpers.sh sing_box_config_facade.sh sing_box_config_manager.sh; do
    [ -s "$lib/$name" ] || fail "missing PE library $name"
    sh -n "$lib/$name" || fail "PE library syntax: $name"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
sed -n '/^configure_outbound_handler() {$/,/^}$/p' "$runtime" > "$work/handler"
sed -n '/^get_subscription_proxy_skip_reason() {$/,/^}$/p' "$runtime" > "$work/skip"

cat > "$work/harness" <<'EOF'
set -e
config='BASE'
config_get() {
    case "$3" in
        connection_type) value=proxy ;;
        proxy_config_type) value="$MODE" ;;
        urltest_proxy_links) value='vless://manual' ;;
        urltest_fallback_links) value='vless://fallback' ;;
        urltest_download_check) value=custom ;;
        urltest_download_url) value='https://speed.example/file' ;;
        urltest_check_interval) value=3m ;;
        urltest_tolerance) value=50 ;;
        urltest_testing_url) value='https://check.example/204' ;;
        enable_udp_over_tcp) value=0 ;;
        *) value="${4:-}" ;;
    esac
    eval "$1=\$value"
}
log() { :; }
sing_box_has_feature() { [ "$FEATURES" = yes ]; }
get_outbound_tag_by_section() { printf 'tag-%s\n' "$1"; }
comma_string_to_json_array() { printf '[%s]' "$1"; }
sing_box_cf_add_proxy_outbound() { printf '%s|proxy:%s:%s\n' "$1" "$2" "$3"; }
sing_box_cm_add_urltest_outbound() {
    printf '%s|urltest:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "${9:-}" "${10:-}" "${11:-}"
}
sing_box_cm_add_selector_outbound() { printf '%s|selector:%s:%s\n' "$1" "$2" "$3"; }
collect_urltest_proxy_links() { printf '%s\n' 'vless://manual' > "$2"; }
section_has_subscription_urls() { return 0; }
load_subscription_proxy_links_for_section() { printf '%s\n' 'vless://subscription' > "$2"; }
url_get_scheme() { printf 'vless\n'; }
url_get_host() { printf 'example.com\n'; }
url_get_port() { printf '443\n'; }
url_get_userinfo() { printf 'valid-uuid\n'; }
is_valid_proxy_port() { return 0; }
is_valid_vless_uuid() { return 0; }
url_get_query_param() {
    case "$2" in type) printf 'xhttp\n';; security) printf 'tls\n';; esac
}
EOF
printf '. "%s"\n. "%s"\n' "$work/handler" "$work/skip" >> "$work/harness"
cat >> "$work/harness" <<'EOF'
configure_outbound_handler demo
printf '%s\n' "$config"
if reason="$(get_subscription_proxy_skip_reason 'vless://valid-uuid@example.com:443?type=xhttp&security=tls')"; then
    printf 'SKIP:%s\n' "$reason"
else
    printf 'SUPPORTED\n'
fi
EOF

output="$(MODE=subscription_urltest FEATURES=yes sh "$work/harness")"
printf '%s\n' "$output" | grep -Fq 'proxy:demo-fallback-1:vless://fallback' || fail 'subscription fallback outbound missing'
printf '%s\n' "$output" | grep -Fq '|urltest:tag-demo-urltest:[tag-demo-1,tag-demo-2]:[tag-demo-fallback-1]:custom:https://speed.example/file' || fail 'subscription PE urltest arguments missing'
printf '%s\n' "$output" | grep -Fq '|selector:tag-demo:[tag-demo-1,tag-demo-2,tag-demo-fallback-1,tag-demo-urltest]' || fail 'subscription selector excludes fallback'
printf '%s\n' "$output" | grep -Fxq SUPPORTED || fail 'XHTTP marked unsupported despite decode-link capability'

output="$(MODE=subscription_urltest FEATURES=no sh "$work/harness")"
printf '%s\n' "$output" | grep -Fq '|urltest:tag-demo-urltest:[tag-demo-1,tag-demo-2]:[]:default:' || fail 'PE fields not omitted for legacy engine'
printf '%s\n' "$output" | grep -Fxq 'SKIP:unsupported_transport' || fail 'XHTTP not gated for legacy engine'
if printf '%s\n' "$output" | grep -Fq 'proxy:demo-fallback-1'; then fail 'fallback retained without engine support'; fi

output="$(MODE=urltest FEATURES=yes sh "$work/harness")"
printf '%s\n' "$output" | grep -Fq '|urltest:tag-demo-urltest:[tag-demo-1]:[tag-demo-fallback-1]:custom:https://speed.example/file' || fail 'native PE URLTest behavior missing'

# Exercise the installed PE JSON builder, not just the handler argument seam.
json="$(sh -c '. "$1"; sing_box_cm_add_urltest_outbound '\''{"outbounds":[]}'\'' auto '\''["primary"]'\'' https://check.example/204 3m 50 "" "" '\''["backup"]'\'' custom https://speed.example/file' sh "$lib/sing_box_config_manager.sh")"
printf '%s\n' "$json" | jq -e '.outbounds[0] | .type == "urltest" and .outbounds == ["primary"] and .fallbacks == ["backup"] and .download_url == "https://speed.example/file"' >/dev/null || fail 'PE JSON builder dropped fallback/download fields'
json="$(sh -c '. "$1"; sing_box_cm_add_urltest_outbound '\''{"outbounds":[]}'\'' auto '\''["primary"]'\'' https://check.example/204 3m 50 "" "" '\''[]'\'' default ""' sh "$lib/sing_box_config_manager.sh")"
printf '%s\n' "$json" | jq -e '.outbounds[0] | (has("fallbacks") | not) and (has("download_url") | not)' >/dev/null || fail 'PE JSON builder emitted unsupported optional fields'

grep -Fq 'tools decode-link --compact' "$lib/sing_box_config_facade.sh" || fail 'XHTTP decode-link library missing'
grep -Fq 'sing_box_get_features()' "$lib/helpers.sh" || fail 'sing-box feature detection missing'
grep -Fq 'download_check' "$lib/sing_box_config_manager.sh" || fail 'PE URLTest JSON builder missing'
grep -Fq 'get_sing_box_features)' "$runtime" || fail 'native PE capability endpoint missing'
printf '%s\n' 'PASS: PE runtime assembly, feature fallback, and XHTTP classification'
