#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
# Model the download fallback installed into the stock helper library.
printf '%s\n' 'raw.githubusercontent.com:443' > "$work/helpers"
for version in 0.7.20 0.7.22; do
    cp "$repo/openwrt/runtime-$version/usr/bin/podkop" "$work/runtime"
    sed -i 's/wget -T 30 -t 1 /wget -T 30 /g' "$work/runtime"
    PODKOP_MAINTENANCE_TARGET="$work/runtime" PODKOP_MAINTENANCE_HELPERS_TARGET="$work/helpers" \
        sh "$repo/openwrt/podkop-subscription-maintenance-upgrade.sh"
    # Match the real installer: update-center repair follows maintenance.
    PODKOP_UPDATE_CENTER_TARGET="$work/runtime" PODKOP_UPDATE_CENTER_SHELL=sh \
        sh "$repo/openwrt/podkop-update-center-upgrade.sh"
    # The installer finalizes the legacy updater timeout after maintenance.
    sed -i 's/run_with_timeout 240 env PODKOP_PATCH_VERSION=/run_with_timeout 900 env PODKOP_PATCH_VERSION=/g' "$work/runtime"
    sed -n '/^# subscription_isolated_probe_v1 begin$/,/^# subscription_isolated_probe_v1 end$/p' "$work/runtime" > "$work/probe"
    cmp -s "$work/probe" "$repo/openwrt/podkop-subscription-probe.sh" || {
        diff -u "$repo/openwrt/podkop-subscription-probe.sh" "$work/probe" >&2 || true
        echo 'FAIL: maintenance upgrade overwrites the isolated subscription probe' >&2
        exit 1
    }
    sed -n '/^has_latest_subscription_backend() {/,/^}/p' "$repo/i" |
        sed "s| /usr/bin/podkop 2>| $work/runtime 2>|g; s|/usr/lib/podkop/helpers.sh|$work/helpers|g" > "$work/predicate"
    . "$work/predicate"
    if ! has_latest_subscription_backend; then
        echo "FAIL: installer rejects the delivered $version backend as outdated" >&2
        exit 1
    fi
done
echo 'PASS: installer recognizes the delivered backend and permits no-op updates'
