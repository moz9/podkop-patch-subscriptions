#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
target="$work/podkop"
cp "$repo/openwrt/runtime-0.7.22/usr/bin/podkop" "$target"
repair() {
    PODKOP_UPDATE_CENTER_TARGET="$target" PODKOP_UPDATE_CENTER_SHELL=sh sh "$repo/openwrt/podkop-update-center-upgrade.sh"
}
check() {
    sh -n "$target"
    [ "$(grep -c '/usr/bin/podkop-update-manager update_start' "$target")" -eq 1 ]
    [ "$(grep -c '/usr/bin/podkop-update-manager status' "$target")" -eq 1 ]
    [ "$(grep -c '^subscription_patch_update_check() {' "$target")" -eq 1 ]
    [ "$(grep -c '^get_subscription_patch_update_log() {' "$target")" -eq 1 ]
    [ "$(grep -c '^subscription_patch_update_check)' "$target")" -eq 1 ]
    [ "$(grep -c '^get_subscription_patch_update_log)' "$target")" -eq 1 ]
}
repair
check
cp "$target" "$work/full"
# Maintenance can replace only the update function while leaving the other helpers.
awk '
/^subscription_patch_update\(\) \{$/ {drop=4; print; next}
drop {drop--; next}
{print}
' "$target" > "$work/partial"
cp "$work/partial" "$target"
repair
check
cmp -s "$target" "$work/full"
repair
cmp -s "$target" "$work/full"
echo 'PASS: update center repairs a missing launch wrapper without duplicating helpers; full upgrade is idempotent'
