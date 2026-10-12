#!/bin/sh
# Compile and execute every service-tag rule generator with the installed jq.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$work/base.json" <<'JSON'
{"dns":{"servers":[{"tag":"existing-dns"}],"rules":[{"action":"reject","domain":["existing.example"]}]},"route":{"final":"existing-out","rules":[{"action":"sniff"}]},"experimental":{"cache_file":{"enabled":true}}}
JSON
base="$(cat "$work/base.json")"
for version in 0.7.23 0.7.24; do
    manager="$repo/openwrt/runtime-$version/usr/lib/podkop/sing_box_config_manager.sh"
    [ -f "$manager" ] || fail "missing config manager: $version"
    # A bare $variable object key was introduced in jq 1.7. Keep this guard
    # so local tests on newer jq still catch incompatible generator syntax.
    if grep -Eq '(^|[{,])[[:space:]]*\$[[:alpha:]_][[:alnum:]_]*[[:space:]]*:' "$manager"; then
        fail "jq 1.6 requires parentheses around dynamic object keys: $version"
    fi
    # This library only defines functions and its service-tag constant.
    # No runtime entrypoint or router command is executed.
    . "$manager"
    for SERVICE_TAG in __service_tag custom_service_tag; do
        sing_box_cm_add_dns_route_rule "$base" dns-server dns-rule > "$work/dns.json" || fail "DNS route generator failed: $version"
        sing_box_cm_add_route_rule "$base" route-rule input output > "$work/route.json" || fail "route generator failed: $version"
        sing_box_cm_add_reject_route_rule "$base" reject-rule input > "$work/reject.json" || fail "reject generator failed: $version"
        sing_box_cm_add_options_route_rule "$base" options-rule > "$work/options.json" || fail "route-options generator failed: $version"
        jq -e --arg key "$SERVICE_TAG" --slurpfile source "$work/base.json" '
            .==($source[0] | .dns.rules += [{action:"route",server:"dns-server",($key):"dns-rule"}])
        ' "$work/dns.json" >/dev/null || fail "DNS rule lost dynamic tag or existing config: $version"
        jq -e --arg key "$SERVICE_TAG" --slurpfile source "$work/base.json" '
            .==($source[0] | .route.rules += [{action:"route",inbound:"input",outbound:"output",($key):"route-rule"}])
        ' "$work/route.json" >/dev/null || fail "route rule lost dynamic tag or existing config: $version"
        jq -e --arg key "$SERVICE_TAG" --slurpfile source "$work/base.json" '
            .==($source[0] | .route.rules += [{action:"reject",inbound:"input",($key):"reject-rule"}])
        ' "$work/reject.json" >/dev/null || fail "reject rule lost dynamic tag or existing config: $version"
        jq -e --arg key "$SERVICE_TAG" --slurpfile source "$work/base.json" '
            .==($source[0] | .route.rules += [{action:"route-options",($key):"options-rule"}])
        ' "$work/options.json" >/dev/null || fail "route-options rule lost dynamic tag or existing config: $version"
    done
done
printf 'PASS: all four rule generators preserve dynamic tags and existing config in both runtime libraries with %s\n' "$(jq --version)"
