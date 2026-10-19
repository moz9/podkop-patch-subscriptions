#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo/openwrt/podkop-service-checks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
subscription_tags_json() { case "$2" in subscription_required_services) echo "$explicit";; community_lists) echo "$lists";; esac; }
explicit='[]'; lists='["google_ai"]'
[ "$(subscription_required_services_json main)" = '["gemini"]' ] || fail 'selected Google AI list omitted Gemini requirement'
explicit='["exit_country"]'; lists='["google_ai","unknown_list","youtube"]'
[ "$(subscription_required_services_json main)" = '["exit_country","gemini"]' ] || fail 'explicit requirement lost or unused service added'
explicit='[]'; lists='["youtube","unknown_list"]'
[ "$(subscription_required_services_json main)" = '[]' ] || fail 'unrelated section acquired expensive checks'
lists='["google_ai","google_ai"]'; explicit='["gemini"]'
[ "$(subscription_required_services_json main)" = '["gemini"]' ] || fail 'duplicate service'
echo 'PASS: known selected-list requirement, explicit controls preserved, unrelated/unknown lists add no probes'
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
printf "config section 'main'\n" > "$work/committed"
PODKOP_DNS_COMMITTED_FILE="$work/committed"
uci() {
 case "$*" in
  '-q get /proc/self/fd/3.main.subscription_required_services') echo gemini;;
  '-q get /proc/self/fd/3.main.community_lists') echo youtube;;
  *) return 1;;
 esac
}
explicit='["chatgpt"]'; lists='["google_ai"]'
[ "$(subscription_required_services_json main)" = '["gemini"]' ] || fail 'DNS continuation used pending service requirements'
echo 'PASS: DNS continuation reads committed service requirements, never a pending filter draft'
