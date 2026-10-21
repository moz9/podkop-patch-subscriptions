#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo/openwrt/podkop-service-checks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
subscription_tags_json() { case "$2" in subscription_required_services) echo "$explicit";; community_lists) echo "$lists";; esac; }
explicit='[]'; lists='["google_ai"]'
[ "$(subscription_required_services_json main)" = '[]' ] || fail 'route list silently enabled Gemini filter'
explicit='["exit_country"]'; lists='["google_ai","unknown_list","youtube"]'
[ "$(subscription_required_services_json main)" = '["exit_country"]' ] || fail 'route list changed explicit filter choice'
explicit='[]'; lists='["youtube","unknown_list"]'
[ "$(subscription_required_services_json main)" = '[]' ] || fail 'unrelated section acquired expensive checks'
lists='["google_ai","google_ai"]'; explicit='["gemini"]'
[ "$(subscription_required_services_json main)" = '["gemini"]' ] || fail 'duplicate service'
explicit='["gemini"]'; lists='["google_ai"]'
[ "$(subscription_required_services_json main '["chatgpt"]')" = '["chatgpt"]' ] || fail 'proposal did not replace saved choices exactly'
[ "$(subscription_required_services_json main '[]')" = '[]' ] || fail 'route list overrode explicit empty proposal'
lists='["youtube"]'
[ "$(subscription_required_services_json main '[]')" = '[]' ] || fail 'empty proposal without list requirements must disable filtering'
subscription_required_services_json main '["invalid"]' >/dev/null && fail 'invalid proposed services accepted' || :
echo 'PASS: route lists never enable service filters; explicit choices and empty proposals are preserved'
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
