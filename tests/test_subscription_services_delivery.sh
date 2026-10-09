#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    grep -Fqx '# subscription_services_v1 begin' "$runtime" || fail 'runtime service helper missing'
    sed -n '/^# subscription_services_v1 begin$/,/^# subscription_services_v1 end$/p' "$runtime" > "$tmp/helper"
    cmp "$tmp/helper" "$repo/openwrt/podkop-service-checks.sh" || fail 'runtime helper drift'
    grep -Fqx '# subscription_service_snapshot_v1 end' "$runtime" || fail 'runtime exact snapshot preservation missing'
    for route in subscription_services_check subscription_services_confirm get_subscription_services; do
        [ "$(grep -c "^$route)" "$runtime")" -eq 1 ] || fail "route $route missing or duplicated"
    done
    sed '/^# subscription_service_filter_v1$/d' "$runtime" > "$tmp/old"
    PODKOP_SOURCES_TARGET="$tmp/old" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    grep -Fqx '# subscription_service_filter_v1' "$tmp/old" || fail 'old marker shortcut skipped update'
    for route in subscription_services_check subscription_services_confirm get_subscription_services; do
        [ "$(grep -c "^$route)" "$tmp/old")" -eq 1 ] || fail "delivery route $route duplicated"
    done
    cp "$tmp/old" "$tmp/once"
    PODKOP_SOURCES_TARGET="$tmp/old" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    cmp "$tmp/once" "$tmp/old" || fail 'service delivery not idempotent'
    # Actual pre-service target: helper/routes absent and previously deployed v2 probe.
    awk '
        /^# subscription_(services|service_snapshot)_v1 begin$/ { block=1; next }
        block { if($0 ~ /^# subscription_(services|service_snapshot)_v1 end$/) block=0; next }
        /^(start_main|start|sing_box_init_config|subscription_reload_seamless)\(\) \{$/ { print; print "    :"; fn=1; next }
        fn { if($0=="}") {print; fn=0}; next }
        /^# subscription_service_filter_v1$/ { next }
        /^subscription_services_check\)$/ || /^subscription_services_confirm\)$/ || /^get_subscription_services\)$/ { route=1; next }
        route { if($0 ~ /;;/) route=0; next }
        { gsub(/subscription_isolated_probe_v1/,"subscription_isolated_probe_v2"); print }
    ' "$runtime" > "$tmp/pre-service"
    PODKOP_SOURCES_TARGET="$tmp/pre-service" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    [ "$(grep -c '^subscription_isolated_test() {' "$tmp/pre-service")" -eq 1 ] || fail 'v2 retrofit duplicated isolated worker'
    grep -Fqx '# subscription_services_v1 end' "$tmp/pre-service" || fail 'pre-service retrofit helper missing'
    grep -Fqx '# subscription_service_snapshot_v1 end' "$tmp/pre-service" || fail 'pre-service retrofit preservation missing'
    for name in start_main start sing_box_init_config subscription_reload_seamless; do
        sed -n "/^$name() {$/,/^}$/p" "$runtime" > "$tmp/canonical-function"
        sed -n "/^$name() {$/,/^}$/p" "$tmp/pre-service" > "$tmp/delivered-function"
        cmp "$tmp/canonical-function" "$tmp/delivered-function" || fail "lifecycle $name was not upgraded"
    done
    for route in subscription_services_check subscription_services_confirm get_subscription_services; do
        [ "$(grep -c "^$route)" "$tmp/pre-service")" -eq 1 ] || fail "pre-service retrofit route $route missing"
    done
    sh -n "$runtime" "$tmp/old"
done
echo 'PASS: runtime helper parity, routes, retrofit and idempotency'
