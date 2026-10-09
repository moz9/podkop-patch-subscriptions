#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$repo/openwrt/podkop-service-checks.sh" ] || fail 'service checks helper missing'
. "$repo/openwrt/podkop-subscription-sources.sh"
. "$repo/openwrt/podkop-service-checks.sh"
. "$repo/openwrt/podkop-subscription-probe.sh"
grep -Fq -- '--connect-timeout 2 -m 4' "$repo/openwrt/podkop-service-checks.sh" || fail 'fast network budget missing'
[ "$(grep -c 'https://chatgpt.com/backend-anon/models' "$repo/openwrt/podkop-service-checks.sh")" -eq 1 ] || fail 'ChatGPT endpoint not single fixed GET'
PODKOP_SERVICE_CACHE_DIR="$tmp/state"
config_get() { eval "$1=''"; }
required_fixture='[]'
config_list_foreach() {
    [ "$2" = subscription_required_services ] || return 0
    printf '%s' "$required_fixture" | jq -r '.[]' > "$tmp/required.list"
    while IFS= read -r value; do "$3" "$value"; done < "$tmp/required.list"
}
subscription_reload_pending_file() { printf '%s/pending\n' "$tmp"; }
subscription_services_context() { printf 'test-context\n'; }
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { [ "$1" = main ]; }
validate_subscription_link_id() { case "$1" in *[!a-f0-9]*) return 1;; esac; [ "${#1}" = 32 ]; }
subscription_runtime_busy() { return 1; }
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { :; }
subscription_services_snapshot_capacity() { return 0; }
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
get_subscription_items_cache_path() { printf '%s/items\n' "$tmp"; }
printf '[{"id":"%s","supported":true,"name":"SE"}]\n' "$id" > "$tmp/items"
subscription_services_check '../invalid' "$id" '["gemini"]' > "$tmp/error" && fail 'invalid section entered worker' || :
jq -e '.error=="invalid_section"' "$tmp/error" >/dev/null
subscription_action_lock_acquire() { return 1; }
subscription_services_check main "$id" '["gemini"]' > "$tmp/error" && fail 'busy lock entered worker' || :
jq -e '.error=="service_busy"' "$tmp/error" >/dev/null
subscription_services_confirm main "$id" gemini true > "$tmp/error" && fail 'busy lock accepted confirmation' || :
jq -e '.error=="service_busy"' "$tmp/error" >/dev/null
subscription_action_lock_acquire() { return 0; }
subscription_services_validate '["gemini","chatgpt"]' || fail 'catalog accepted list'
! subscription_services_validate '["gemini","gemini"]' || fail 'duplicate catalog ids accepted'
! subscription_services_validate '["api"]' || fail 'unknown catalog ids accepted'
result="$(subscription_services_classify gemini 0 200 '<html>Sign in</html>')"
printf '%s' "$result" | jq -e '.state=="unknown" and .network=="pass"' >/dev/null || fail 'HTTP200 must not prove Gemini Web'
subscription_services_classify gemini 0 200 'Gemini is not available in your country' | jq -e '.state=="fail"' >/dev/null || fail 'region denial not rejected'
subscription_services_classify chatgpt 28 000 '' | jq -e '.state=="fail" and .network=="fail"' >/dev/null || fail 'timeout not rejected'
subscription_services_classify gemini 0 200 '<html>Gemini 45631641,null,true</html>' | jq -e '.state=="pass" and .manual==false and .reason=="region_precheck_passed"' >/dev/null || fail 'Gemini positive eligibility marker not recognized'
subscription_services_classify gemini 0 200 'Gemini 45631641,null,true' | jq -e '.state=="unknown"' >/dev/null || fail 'plain text Gemini marker accepted'
subscription_services_classify gemini 0 200 'arbitrary body 45631641,null,true' | jq -e '.state=="unknown"' >/dev/null || fail 'arbitrary 200 body accepted'
subscription_services_classify gemini 0 403 'captcha cf-chl-' | jq -e '.state=="unknown" and .network=="pass" and .reason=="challenge_required"' >/dev/null || fail 'challenge misreported as region denial or blocks manual fallback'
subscription_services_classify gemini 28 200 '<html>captcha</html>' | jq -e '.state=="fail" and .network=="fail"' >/dev/null || fail 'timeout body overrides transport failure'
subscription_services_classify chatgpt 0 200 '{"models":[{"slug":"model"}]}' | jq -e '.state=="pass" and .reason=="anonymous_models_available"' >/dev/null || fail 'anonymous models evidence unrecognized'
subscription_services_classify chatgpt 0 200 '{"models":[]}' | jq -e '.state=="unknown"' >/dev/null || fail 'empty models accepted'
subscription_services_classify chatgpt 0 200 '{"models":[{}]}' | jq -e '.state=="unknown"' >/dev/null || fail 'invalid model accepted'
subscription_services_classify chatgpt 0 200 '{not-json}' | jq -e '.state=="unknown"' >/dev/null || fail 'malformed model JSON accepted'
subscription_services_classify chatgpt 0 403 '{"error":{"code":"unsupported_country"}}' | jq -e '.state=="fail" and .reason=="region_denied"' >/dev/null || fail 'explicit JSON region denial unrecognized'
# Run the real network worker with only HTTP transport replaced by fixed fixtures.
fixture_failure=0
curl() {
    output=''; endpoint=''
    while [ "$#" -gt 0 ]; do
        case "$1" in -o) output="$2"; shift 2;; https://*) endpoint="$1"; shift;; *) shift;; esac
    done
    printf '%s\n' "$endpoint" >> "$tmp/requests"
    if [ "$fixture_failure" = 1 ]; then printf '{"error":{"code":"unsupported_country"}}' > "$output"; printf 403
    elif [ "$endpoint" = https://gemini.google.com/ ]; then printf '<html>Gemini 45631641,null,true</html>' > "$output"; printf 200
    elif [ "$endpoint" = https://chatgpt.com/backend-anon/models ]; then printf '{"models":[{"id":"model"}]}' > "$output"; printf 200
    else fail 'unexpected network destination'; fi
}
subscription_services_probe main "$id" '["gemini","chatgpt"]' http://127.0.0.1:9 "$tmp" | jq -e '.success and all(.services[]; .state=="pass")' >/dev/null || fail 'fixture worker did not classify actual responses'
[ "$(wc -l < "$tmp/requests")" = 2 ] || fail 'more than one GET per selected service'
fixture_failure=1
: > "$tmp/requests"
subscription_services_probe main "$id" '["gemini","chatgpt"]' http://127.0.0.1:9 "$tmp" | jq -e '.services.gemini.state=="fail" and .services.chatgpt.reason=="skipped_after_failure"' >/dev/null || fail 'AND worker did not stop after definitive failure'
[ "$(wc -l < "$tmp/requests")" = 1 ] || fail 'AND worker probed unnecessarily after failure'
services='{"required":["gemini"],"results":[]}'
subscription_source_policy '[]' '[]' "$tmp/items" auto '[]' '[]' '[]' "$services" | jq -e '.[0].serviceExcluded and (.[0].runtimeEnabled|not)' >/dev/null || fail 'unknown evidence admitted'
subscription_services_store main "$id" '{"gemini":{"state":"pass","network":"pass","reason":"region_precheck_passed"}}'
subscription_services_confirm main "$id" gemini true > "$tmp/error" && fail 'automatic pass allowed manual positive override' || :
jq -e '.error=="confirmation_requires_unknown_state"' "$tmp/error" >/dev/null
subscription_services_confirm main "$id" gemini false | jq -e '.success' >/dev/null || fail 'fresh pass cannot be manually revoked'
subscription_services_confirm main "$id" gemini true > "$tmp/error" && fail 'manual negative overridden without new check' || :
jq -e '.error=="confirmation_requires_unknown_state"' "$tmp/error" >/dev/null
subscription_services_store main "$id" '{"gemini":{"state":"unknown","network":"pass","reason":"confirmation_required"}}'
input_before="$(sha256sum "$tmp/items")"
[ ! -f "$tmp/pending" ] || fail 'draft/off checks marked an activation pending'
required_fixture='["gemini"]'
subscription_services_store main "$id" '{"gemini":{"state":"unknown","network":"pass","reason":"confirmation_required"}}'
[ -f "$tmp/pending" ] || fail 'already-enabled filter check did not mark pending'
printf 'previous pending marker\n' > "$tmp/pending"
subscription_services_store main "$id" '{"gemini":{"state":"unknown","network":"pass","reason":"confirmation_required"}}'
[ "$(cat "$tmp/pending")" = 'previous pending marker' ] || fail 'service check truncated the existing pending marker'
rm "$tmp/pending"
cache_before="$(sha256sum "$(subscription_services_cache_path main)")"
touch() { return 1; }
subscription_services_store main "$id" '{"gemini":{"state":"fail","network":"fail"}}' && fail 'pending failure accepted updated service cache' || :
[ "$cache_before" = "$(sha256sum "$(subscription_services_cache_path main)")" ] || fail 'pending failure changed old service evidence'
subscription_services_confirm main "$id" gemini true > "$tmp/error" && fail 'pending failure accepted confirmation' || :
[ "$cache_before" = "$(sha256sum "$(subscription_services_cache_path main)")" ] || fail 'pending failure changed confirmation evidence'
unset -f touch
subscription_services_confirm main "$id" gemini true | jq -e '.success' >/dev/null || fail 'recent valid confirmation rejected'
[ -f "$tmp/pending" ] || fail 'already-enabled filter confirmation did not mark pending'
[ "$(stat -c %a "$tmp/pending")" = 600 ] || fail 'service pending marker not private'
[ "$input_before" = "$(sha256sum "$tmp/items")" ] || fail 'service evidence check/confirmation activated cache changes'
required_fixture='[]'
rm "$tmp/pending"
subscription_services_store main "$id" '{"gemini":{"state":"unknown","network":"pass","reason":"confirmation_required"}}'
subscription_services_confirm main "$id" gemini true | jq -e '.success' >/dev/null
[ ! -f "$tmp/pending" ] || fail 'off-filter confirmation marked pending'
service_policy="$(subscription_services_policy main '["gemini"]')"
subscription_source_policy '[]' '[]' "$tmp/items" auto '[]' '[]' '[]' "$service_policy" | jq -e '.[0].runtimeEnabled and (.[0].serviceExcluded|not)' >/dev/null || fail 'confirmed recent exact id rejected'
subscription_services_store main "$id" '{"gemini":{"state":"fail","network":"fail","reason":"network_failed"}}'
subscription_services_confirm main "$id" gemini true > "$tmp/error" && fail 'failed network confirmed' || :
jq -e '.error=="recent_network_check_required"' "$tmp/error" >/dev/null
service_policy="$(subscription_services_policy main '["gemini"]')"
subscription_source_policy '[]' '[]' "$tmp/items" auto '[]' '[]' '[]' "$service_policy" | jq -e '.[0].serviceExcluded' >/dev/null || fail 'old manual confirmation survived network fail'
subscription_services_context() { printf 'changed-profile\n'; }
subscription_services_policy main '["gemini"]' | jq -e '.results==[]' >/dev/null || fail 'changed context reused evidence'
subscription_services_context() { printf 'test-context\n'; }
path="$(subscription_services_cache_path main)"
jq '.results[].expiresAt=0' "$path" > "$tmp/expired"; mv "$tmp/expired" "$path"
subscription_services_policy main '["gemini"]' | jq -e '.results==[]' >/dev/null || fail 'expired evidence admitted'
subscription_services_store main bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '{"gemini":{"state":"unknown","network":"pass","reason":"confirmation_required"}}'
jq -e --arg id "$id" 'any(.results[]; .id==$id and .expiresAt==0)' "$path" >/dev/null || fail 'unrelated new check discarded expired admitted-row identity'
subscription_services_confirm main "$id" gemini true > "$tmp/error" && fail 'expired network confirmed' || :
jq -e '.error=="recent_network_check_required"' "$tmp/error" >/dev/null
now="$(date +%s)"
jq -cn --arg id "$id" --argjson now "$now" '{context:"test-context",results:[null,-1,($now+1)]|map({id:$id,checkedAt:.,expiresAt:($now+3600),services:{gemini:{state:"pass"}}})}' > "$path"
subscription_services_policy main '["gemini"]' | jq -e '.results==[]' >/dev/null || fail 'malformed or future checkedAt evidence admitted'
jq -cn --arg id "$id" --argjson now "$now" '{context:"test-context",results:[{id:$id,checkedAt:$now,expiresAt:($now+86401),services:{gemini:{state:"pass"}}}]}' > "$path"
subscription_services_policy main '["gemini"]' | jq -e '.results==[]' >/dev/null || fail 'out-of-bounds TTL evidence admitted'
jq -cn --argjson now "$now" '{context:"test-context",results:[range(0;300)|{id:(("00000000000000000000000000000000"+tostring)[-32:]),checkedAt:$now,expiresAt:($now+86400),services:{}}]}' > "$path"
subscription_services_store main "$id" '{"gemini":{"state":"fail","network":"fail","reason":"network_failed"}}'
[ "$(jq '.results|length' "$path")" = 301 ] || fail 'many-config cache churns after 256 rows'
jq -cn --argjson now "$now" '{context:"test-context",results:[range(0;2049)|{id:(("00000000000000000000000000000000"+tostring)[-32:]),checkedAt:$now,expiresAt:($now+86400),services:{gemini:{state:"pass",network:"pass",reason:"region_precheck_passed",manual:false,httpCode:200},chatgpt:{state:"pass",network:"pass",reason:"anonymous_models_available",manual:false,httpCode:200}}}]}' > "$path"
subscription_services_store main "$id" '{"gemini":{"state":"pass","network":"pass","reason":"region_precheck_passed"}}' || fail 'large real-shaped cache cannot be updated'
[ "$(jq '.results|length' "$path")" = 2048 ] || fail 'service cache is not bounded to 2048 rows'
service_policy="$(subscription_services_policy main '["gemini"]')" || fail 'large evidence policy cannot be produced'
subscription_source_policy '[]' '[]' "$tmp/items" auto '[]' '[]' '[]' "$service_policy" | jq -e '.[0].runtimeEnabled' >/dev/null || fail 'large evidence pool cannot be applied'
get_subscription_services main | jq -e '.capacity==2048 and (.results|length)==2048' >/dev/null || fail 'large evidence pool cannot be returned to UI'
subscription_services_context() { printf 'changed-profile\n'; }
SUBSCRIPTION_APPLY_V2_TMP="$tmp"
subscription_items_with_sources() { cat "$2"; }
get_subscription_sources() { printf '[]\n'; }
printf '[]\n' > "$tmp/tags.main.include"
printf '[]\n' > "$tmp/tags.main.exclude"
subscription_sources_prepare main '{"changes":[],"requiredServices":["gemini"]}' "$tmp/items" '[]'
[ "$SUBSCRIPTION_SOURCES_REMAINING" = 0 ] || fail 'transaction did not enforce proposed requirements'
[ "$SUBSCRIPTION_SOURCES_CHANGED" = 1 ] || fail 'requirement changes not counted'
collect_urltest_proxy_links() { printf 'manual-link\n' > "$2"; return 0; }
subscription_sources_prepare main '{"changes":[],"requiredServices":["gemini"]}' "$tmp/items" '[]' && fail 'untested manual mix admitted' || :
[ "$SUBSCRIPTION_SOURCES_ERROR" = service_manual_links_unsupported ] || fail 'manual mix failure is not explicit'
collect_urltest_proxy_links() { return 1; }
subscription_services_snapshot_capacity() { return 1; }
subscription_sources_prepare main '{"changes":[],"requiredServices":["gemini"]}' "$tmp/items" '[]' && fail 'low snapshot space allowed activation prepare' || :
[ "$SUBSCRIPTION_SOURCES_ERROR" = service_snapshot_storage_unavailable ] || fail 'low snapshot storage failure is not explicit'
subscription_services_snapshot_capacity() { return 0; }
subscription_required_services_json() { printf '["gemini"]\n'; }
config_foreach() { "$1" main; }
get_subscription_all_cache_path() { printf '%s/all\n' "$tmp"; }
get_subscription_link_id() { printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
printf 'opaque-test-link\n' > "$tmp/all"
log() { :; }
stop_main() { touch "$tmp/stopped"; }
start_main() { touch "$tmp/started"; }
eval "$(sed -n '/^reload() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop")"
before="$(sha256sum "$tmp/items" "$tmp/all")"
reload && fail 'expired required service did not abort reload' || :
[ ! -e "$tmp/stopped" ] || fail 'empty service pool stopped working runtime'
[ "$before" = "$(sha256sum "$tmp/items" "$tmp/all")" ] || fail 'preflight mutated subscription caches'
eval "$(sed -n '/^subscription_services_context() {$/,/^}$/p' "$repo/openwrt/podkop-service-checks.sh" | sed '1s/subscription_services_context/service_context_failure_test/')"
jq() { return 1; }
service_context_failure_test main >/dev/null 2>&1 && fail 'invalid DNS context silently hashed empty input' || :
jq() { printf '{"servers":[]}\n'; }
context_setting=one
uci() { printf 'podkop.settings.dns_server=%s\n' "$context_setting"; }
context_before="$(service_context_failure_test main)"
context_setting=two
[ "$context_before" != "$(service_context_failure_test main)" ] || fail 'desired DNS settings changes did not invalidate context'
! grep -Eq 'uci .* (set|commit)|clash_api_set|/etc/init.d/' "$repo/openwrt/podkop-service-checks.sh" || fail 'diagnostics mutate production'
echo 'PASS: service catalog, proof classification, exact identity/context, fail-closed policy, confirmation and network override'
