#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
version="$(jq -er '.recommendedPodkopVersion' "$repo/openwrt/update-manifest.json")"
case "$version" in 0.7.22) versions='0.7.20 0.7.22';; 0.7.23|0.7.24) versions="$version";; *) fail 'unsupported fixture version';; esac
cmp -s "$repo/i" "$repo/openwrt/install.sh" || fail 'installer copies diverged'
for version in $versions; do
    for name in subscription_services_context subscription_services_read subscription_services_store subscription_services_google_probe subscription_services_classify subscription_services_probe subscription_services_check; do
        sed -n "/^$name()/,/^}/p" "$repo/openwrt/podkop-service-checks.sh" | tr -d '\r' > "$work/helper"
        sed -n "/^$name()/,/^}/p" "$repo/openwrt/runtime-$version/usr/bin/podkop" | tr -d '\r' > "$work/runtime"
        [ -s "$work/helper" ] && cmp -s "$work/helper" "$work/runtime" || fail "helper/runtime mismatch: $version $name"
    done
done
if grep -q '^db_quick_benchmark()' "$repo/openwrt/podkop-dns-benchmark"; then
    [ -s "$repo/openwrt/podkop-diagnostic-policy.sh" ] || fail 'native policy missing'
    for file in i s openwrt/install.sh; do
        grep -Fq 'podkop-diagnostic-policy.sh' "$repo/$file" || fail "policy not shipped: $file"
    done
    expected="$(jq -er '.sha256["openwrt/podkop-diagnostic-policy.sh"]' "$repo/openwrt/update-manifest.json")"
    actual="$(sha256sum "$repo/openwrt/podkop-diagnostic-policy.sh" | cut -d ' ' -f 1)"
    [ "$expected" = "$actual" ] || fail 'native policy hash stale'
fi
echo 'PASS: changed service functions match shipped runtimes; native policy delivered with exact hash'
