#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { :; }
TMP_RULESET_FOLDER="$work/rules"; mkdir -p "$TMP_RULESET_FOLDER"
SB_FAKEIP_DNS_RULE_TAG=fakeip-dns-rule-tag
SERVICE_TAG=_tag
get_ruleset_tag() { printf '%s-%s-%s-ruleset\n' "$1" "$2" "$3"; }
# Installed core creator contract: rc3 means reuse the existing file.
create_source_rule_set() {
    [ "${creator_failure:-0}" = 0 ] || return 1
    [ ! -f "$1" ] || return 3
    printf '{"version":3,"rules":[]}\n' > "$1"
}
sing_box_cm_add_local_ruleset() {
    printf '%s' "$1" | jq -c --arg tag "$2" --arg format "$3" --arg path "$4"         '.route.rule_set += [{type:"local",tag:$tag,format:$format,path:$path}]'
}
sing_box_cm_patch_route_rule() {
    printf '%s' "$1" | jq -c --arg tag "$2" --arg key "$3" --arg value "$4" '.route.rules |= map(if ._tag==$tag then if has($key) then .[$key] |= (if type=="array" then .+[$value] else [.,$value] end) else .+{($key):$value} end else . end)'
}
sing_box_cm_patch_dns_route_rule() {
    printf '%s' "$1" | jq -c --arg tag "$2" --arg key "$3" --arg value "$4" '.dns.rules |= map(if ._tag==$tag then if has($key) then .[$key] |= (if type=="array" then .+[$value] else [.,$value] end) else .+{($key):$value} end else . end)'
}
reset_config() {
    config='{"route":{"rule_set":[],"rules":[{"_tag":"route-test"}]},"dns":{"servers":[],"rules":[{"_tag":"fakeip-dns-rule-tag"}]}}'
}
versions='0.7.20 0.7.22'
[ ! -f "$repo/openwrt/runtime-0.7.23/usr/bin/podkop" ] || versions="$versions 0.7.23"
for version in $versions; do
    runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
    sed -n '/^prepare_source_ruleset() {$/,/^}$/p' "$runtime" > "$work/function"
    . "$work/function"
    rm -f "$TMP_RULESET_FOLDER/main-user-domains-ruleset.json"
    reset_config
    if ! prepare_source_ruleset main user domains route-test; then fail "$version fresh domain registration failed"; fi
    first_dns="$(printf '%s' "$config" | jq -cS '.dns')"
    [ -f "$TMP_RULESET_FOLDER/main-user-domains-ruleset.json" ] || fail 'creator did not create fixture'
    reset_config
    if ! prepare_source_ruleset main user domains route-test; then fail "$version cached domain registration failed"; fi
    printf '%s' "$config" | jq -e       '.route.rule_set|length==1' >/dev/null || fail "$version cached local ruleset missing"
    [ "$(printf '%s' "$config" | jq -cS '.dns')" = "$first_dns" ] || fail "$version DNS context changed on cache reuse"
    [ "$ruleset_tag" = main-user-domains-ruleset ] || fail 'caller-visible tag lost'
    [ "$ruleset_filepath" = "$TMP_RULESET_FOLDER/main-user-domains-ruleset.json" ] || fail 'caller-visible path lost'
    repeated_before="$config"
    if ! prepare_source_ruleset main user domains route-test; then fail 'repeated registration failed'; fi
    [ "$config" = "$repeated_before" ] || fail "$version duplicate ruleset registration"
    config="$(printf '%s' "$config" | jq -c '.route.rules += [{_tag:"route-other"}]')"
    if ! prepare_source_ruleset main user domains route-other; then fail 'shared file on another route failed'; fi
    printf '%s' "$config" | jq -e '(.route.rule_set|length)==1 and .route.rules[1].rule_set=="main-user-domains-ruleset"' >/dev/null || fail 'second route reference missing or local definition duplicated'
    [ "$(printf '%s' "$config" | jq -cS '.dns')" = "$first_dns" ] || fail 'second route duplicated DNS reference'
    reset_config
    if ! prepare_source_ruleset main user subnets route-test; then fail 'subnet registration failed'; fi
    printf '%s' "$config" | jq -e '(.route.rule_set|length)==1 and .route.rules[0].rule_set=="main-user-subnets-ruleset" and (.dns.rules[0]|has("rule_set")|not)' >/dev/null || fail "$version subnet incorrectly registered in DNS"
    reset_config; failure_before="$config"; creator_failure=1
    if prepare_source_ruleset main failed domains route-test; then fail "$version creator failure silently accepted"; fi
    [ "$config" = "$failure_before" ] || fail 'creator failure mutated config'
    creator_failure=0
done
printf 'PASS: source ruleset reuse preserves DNS context without duplicate registrations\n'
