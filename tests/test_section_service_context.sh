#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for version in 0.7.20 0.7.22; do
    sed -n '/^subscription_services_context() {/,/^}/p' "$root/openwrt/runtime-$version/usr/bin/podkop" > "$tmp/context"
    (
        . "$tmp/context"
        config_get() { udp=0; }
        jq() { printf '%s\n' '{"servers":[]}'; }
        isolation=''
        TEST_DNS=original
        uci() { printf '%s\n' "podkop.settings.dns='$TEST_DNS'"; [ -z "$isolation" ] || printf '%s\n' "podkop.settings.subscription_isolated_section='$isolation'"; return 0; }
        before=$(subscription_services_context main)
        isolation=main
        after=$(subscription_services_context main)
        [ "$before" = "$after" ] || { echo 'FAIL isolation-only migration invalidates existing service proof'; exit 1; }
        TEST_DNS=changed
        [ "$before" != "$(subscription_services_context main)" ] || { echo 'FAIL actual DNS change retained stale proof'; exit 1; }
    )
done
echo 'section service context: PASS'
