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
    PODKOP_INIT_SCRIPT="$work/init"
    ENGINE_INIT_SCRIPT="$work/engine-init"
    export PODKOP_SOURCES_ENGINE_INIT_TARGET="$ENGINE_INIT_SCRIPT"
    printf '%s\n' '#!/bin/sh /etc/rc.common' 'USE_PROCD=1' \
        'start_service() { /usr/bin/podkop start; }' \
        'stop_service() { /usr/bin/podkop stop; }' > "$PODKOP_INIT_SCRIPT"
    printf '%s\n' '#!/bin/sh /etc/rc.common' 'service_triggers() {' '}' > "$ENGINE_INIT_SCRIPT"
    chmod 755 "$PODKOP_INIT_SCRIPT" "$ENGINE_INIT_SCRIPT"
    # Backend freshness also requires the installed rc.common restart guard.
    # Exercise its real delivery rather than inserting the marker by hand.
    PODKOP_INIT_SCRIPT="$work/init"
    printf '%s\n' '#!/bin/sh /etc/rc.common' 'USE_PROCD=1' \
        'start_service() { /usr/bin/podkop start; }' \
        'stop_service() { /usr/bin/podkop stop; }' \
        'reload_service() { /usr/bin/podkop reload; }' > "$PODKOP_INIT_SCRIPT"
    if has_latest_subscription_backend; then
        echo "FAIL: installer accepts an unguarded $version init script" >&2
        exit 1
    fi
    PODKOP_SOURCES_SAFE_RESTART_ONLY=1 PODKOP_SOURCES_TARGET="$work/runtime" \
        PODKOP_SOURCES_SOURCE="$repo/openwrt/runtime-$version/usr/bin/podkop" \
        PODKOP_SOURCES_INIT_TARGET="$PODKOP_INIT_SCRIPT" \
        sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    if ! has_latest_subscription_backend; then
        echo "FAIL: installer rejects the delivered $version backend as outdated" >&2
        exit 1
    fi
done
echo 'PASS: installer recognizes the delivered backend and permits no-op updates'
