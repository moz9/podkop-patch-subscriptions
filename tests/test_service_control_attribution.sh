#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-service-checks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
for control in pass fail unknown; do
    actual="$(subscription_services_classify gemini 28 000 '' "$control")"
    printf '%s' "$actual" | jq -e --arg control "$control" '
      .state=="unknown" and .curlCode==28 and .control==$control and
      (if $control=="pass" then .network=="pass" and .category=="service_error"
       elif $control=="fail" then .category=="node_error"
       else .category=="network_unknown" end)' >/dev/null || fail "transport attribution: $control"
done
subscription_services_classify gemini 0 429 '<html>recaptcha</html>' |
    jq -e '.state=="unknown" and .category=="captcha" and .network=="pass"' >/dev/null || fail 'CAPTCHA incorrectly treated as dead proxy'
subscription_services_classify gemini 0 200 '<html>Gemini ,2,1,200,"SWE"</html>' |
    jq -e '.state=="pass" and .category=="preliminary" and .curlCode==0' >/dev/null || fail 'lost preliminary proof'

printf '%s\n' '[{"id":"node","name":"Sweden"}]' > "$work/items.json"
get_subscription_items_cache_path() { echo "$work/items.json"; }
subscription_services_store() { printf '%s\n' "$3" > "$work/stored.json"; }
fixture_mode=pass
curl() {
    output=''
    for arg do
        if [ "$output" = next ]; then output="$arg"; fi
        [ "$arg" != -o ] || output=next
        url="$arg"
    done
    echo "$url" >> "$work/requests"
    case "$url" in
        https://gemini.google.com/)
            [ "$fixture_mode" != timeout ] || return 28
            printf '%s\n' '<html>Gemini ,2,1,200,"SWE"</html>' > "$output"
            echo 200;;
        https://www.gstatic.com/generate_204) echo 204;;
        *) fail "unrequested endpoint: $url";;
    esac
}
: > "$work/requests"
subscription_services_probe main node '["gemini","google_country"]' socks5h://127.0.0.1:1234 "$work" >/dev/null
[ "$(wc -l < "$work/requests")" = 1 ] || fail 'Gemini and Google duplicated a successful request'
fixture_mode=timeout
: > "$work/requests"
subscription_services_probe main node '["gemini"]' socks5h://127.0.0.1:1234 "$work" >/dev/null
[ "$(wc -l < "$work/requests")" = 2 ] || fail 'transport error must use only one bounded control, no retry storm'
jq -e '.gemini.state=="unknown" and .gemini.category=="service_error" and .gemini.network=="pass"' "$work/stored.json" >/dev/null || fail 'standalone Gemini bypassed shared control classification'
echo 'PASS: Gemini control attribution, CAPTCHA and shared single-request successful path'
