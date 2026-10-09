#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$repo/openwrt/podkop-service-checks.sh"
assert_classification() {
    actual="$(subscription_services_classify gemini "$1" "$2" "$3")"
    printf '%s' "$actual" | jq -e "$4" >/dev/null || fail "$5: $actual"
}
if [ "${1:-all}" != cache ]; then
    assert_classification 0 200 '<html><title>Gemini</title>,2,1,200,"SWE"</html>' '.state=="pass" and .network=="pass" and .region=="SWE" and .reason=="region_precheck_passed" and .manual==false' 'supported Swedish marker'
    assert_classification 0 200 '<!doctype html><title>Gemini</title>,2,1,200,"RUS"</html>' '.state=="fail" and .network=="pass" and .region=="RUS" and .reason=="region_denied"' 'denied Russian marker'
    assert_classification 0 200 '<html>Gemini ,2,1,200,"USA" ,2,1,200,"USA"</html>' '.state=="pass" and .region=="USA"' 'duplicate identical marker'
    assert_classification 0 200 '<html>Gemini without region</html>' '.state=="unknown" and .reason=="region_marker_missing" and .region==null' 'missing marker reason'
    assert_classification 0 200 '<html>Gemini ,2,1,200,"SWE" ,2,1,200,"RUS"</html>' '.state=="unknown" and .reason=="region_marker_ambiguous" and .region==null' 'ambiguous marker reason'
    assert_classification 0 200 '<html>Gemini ,2,1,200,"ZZZ"</html>' '.state=="unknown" and .reason=="region_unknown"' 'unknown country reason'
    for body in \
        '<html>Gemini 45631641,null,true</html>' \
        '<html>Gemini ,2,1,200,"ZZZ"</html>' \
        '<html>Gemini ,2,1,200,"SWE" ,2,1,200,"RUS"</html>' \
        '<html>Gemini ,2,1,200,"SWEextra"</html>' \
        '<html>Gemini ,2,1,200,"swe"</html>' \
        '<html>Gemini ,2,1,200,"SW"</html>' \
        'Gemini ,2,1,200,"SWE"' \
        '<html>Unrelated ,2,1,200,"SWE"</html>' \
        '<html>Gemini ,2,1,200,"HKG"</html>' \
        '<html>Gemini ,2,1,200,"MAC"</html>' \
        '<html>Gemini ,2,1,200,"CHN"</html>'; do
        assert_classification 0 200 "$body" '.state=="unknown" and .network=="pass"' 'unproven region must remain unknown'
    done
    assert_classification 0 200 '<html>Gemini captcha ,2,1,200,"RUS" not available in your country</html>' '.state=="unknown" and .reason=="challenge_required" and .region==null' 'challenge overrides geo text and marker'
    assert_classification 28 200 '<html>Gemini ,2,1,200,"RUS"</html>' '.state=="unknown" and .network=="fail" and .reason=="network_failed" and .region==null' 'timeout is not regional denial'
    assert_classification 0 503 '<html>Gemini ,2,1,200,"SWE"</html>' '.state=="unknown" and .network=="fail" and .reason=="http_failed"' 'HTTP failure is not regional evidence'
    assert_classification 0 403 '<html>Gemini ,2,1,200,"RUS"</html>' '.state=="unknown" and .reason=="challenge_required"' 'non200 marker rejected'
    assert_classification 0 200 'Gemini is not available in your country' '.state=="unknown"' 'nonHTML denial is not trusted Gemini identity'
    assert_classification 0 200 '<html>Gemini is not available in your country</html>' '.state=="unknown" and .region==null' 'missing country marker cannot establish regional denial'
    assert_classification 0 200 '<html>Gemini ,2,1,200,"SWE" ,2,1,200,"RUS" not available in your country</html>' '.state=="unknown" and .region==null' 'ambiguous country marker cannot establish regional denial'
    subscription_services_classify chatgpt 28 000 '' | jq -e '.state=="fail" and .network=="fail"' >/dev/null || fail 'ChatGPT semantics changed'
fi
if [ "${1:-all}" = classify ]; then echo 'PASS: Gemini v2 classification'; exit; fi
PODKOP_SERVICE_CACHE_DIR="$tmp/state"
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_link_id() { [ "$1" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]; }
subscription_services_context() { printf '%s\n' "${fixture_context:-context-v2}"; }
subscription_services_mark_pending() { :; }
fixture_time=100000
date() { [ "$1" = +%s ] || return 1; printf '%s\n' "$fixture_time"; }
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
subscription_services_store main "$id" '{"chatgpt":{"state":"pass","network":"pass","manual":true,"reason":"user_confirmed"}}'
path="$(subscription_services_cache_path main)"
chatgpt_before="$(jq -c '.results[0].services.chatgpt' "$path")"
fixture_time=100100
subscription_services_store main "$id" '{"gemini":{"state":"pass","network":"pass","region":"SWE"}}'
[ "$chatgpt_before" = "$(jq -c '.results[0].services.chatgpt' "$path")" ] || fail 'subset update discarded or renewed unrelated ChatGPT observation'
subscription_services_read main | jq -e '.[0].services.chatgpt.checkedAt==100000 and .[0].services.gemini.checkedAt==100100' >/dev/null || fail 'per-service check times absent'
fixture_time=186401
subscription_services_read main | jq -e '.[0].services.gemini.state=="pass" and (.[0].services|has("chatgpt")|not)' >/dev/null || fail 'subset update renewed expired unrelated proof or dropped fresh Gemini'
fixture_time=186501
subscription_services_read main | jq -e '.==[]' >/dev/null || fail 'expired evidence survived'
fixture_time=100200
fixture_context=context-v3
subscription_services_read main | jq -e '.==[]' >/dev/null || fail 'old context reused evidence'
subscription_services_store main "$id" '{"gemini":{"state":"unknown","network":"pass"}}'
jq -e '(.results[0].services|has("chatgpt")|not)' "$path" >/dev/null || fail 'context change merged old proof'
grep -Fq 'service-web-v2:' "$repo/openwrt/podkop-service-checks.sh" || fail 'old evidence schema context salt remains'
echo 'PASS: Gemini v2 classification, subset preservation, per-service expiry and schema invalidation'
