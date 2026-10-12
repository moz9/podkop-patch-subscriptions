#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$repo/openwrt/podkop-service-checks.sh"
. "$repo/openwrt/podkop-subscription-probe.sh"
subscription_services_classify gemini 28 000 'SECRET-BODY' | jq -e '.curlCode==28 and .reason=="network_failed" and .state=="unknown"' >/dev/null || fail 'transport exit code lost'
PODKOP_PROBE_STATUS_DIR="$tmp/status"
export PODKOP_PROBE_STATUS_DIR
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { return 0; }
validate_subscription_link_id() { [ "$1" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]; }
subscription_runtime_busy() { return 0; }
rc=0
subscription_isolated_test main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa services '["gemini"]' > "$tmp/result" || rc=$?
[ "$rc" = 1 ] || fail 'busy status changed'
jq -e '.success==false and .id=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .section=="main" and .stage=="action_lock" and .error=="service_busy" and (.timestamp|type=="number")' "$tmp/result" >/dev/null || fail 'structured failure identity missing'
jq -S . "$tmp/result" > "$tmp/expected"
jq -S . "$tmp/status/main.json" > "$tmp/actual"
cmp "$tmp/expected" "$tmp/actual" || fail 'last probe evidence not retained'
[ "$(wc -c < "$tmp/status/main.json")" -lt 4096 ] || fail 'diagnostic record unbounded'
! grep -q 'SECRET-BODY' "$tmp/status/main.json" || fail 'body leaked'
before="$(sha256sum "$tmp/status/main.json")"
subscription_probe_diagnostic main bad config_check invalid_config false
[ "$before" = "$(sha256sum "$tmp/status/main.json")" ] || fail 'unvalidated identity overwrote diagnostic'
subscription_services_store() { return 1; }
rc=0
subscription_services_probe main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '[]' 'http://127.0.0.1:1' "$tmp" > "$tmp/store-result" || rc=$?
[ "$rc" = 1 ] && [ "$probe_stage" = evidence_store ] && [ "$SUBSCRIPTION_PROBE_ERROR" = evidence_store_failed ] || fail 'store failure not distinguished'
echo 'PASS: isolated failure identity, bounded retained record and curl exit code'
