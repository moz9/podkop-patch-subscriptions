#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=${1:-$repo/openwrt/runtime-0.7.22/usr/bin/podkop}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$fixture" "$work/runtime"
if [ "$#" = 0 ]; then
 awk '
 {print}
 $0=="subscription_update() {" {
  print "    if ! subscription_action_lock_acquire \"speedtest\"; then"
  print "        return 1"
  print "    fi"
  print "    trap '\''subscription_action_lock_release'\'' EXIT INT TERM"
 }' "$work/runtime" > "$work/bad"
 cp "$work/bad" "$work/runtime"
fi
printf '%s\n' 'raw.githubusercontent.com:443' > "$work/helpers"
for pass in 1 2; do
 PODKOP_MAINTENANCE_TARGET="$work/runtime" PODKOP_MAINTENANCE_HELPERS_TARGET="$work/helpers" sh "$repo/openwrt/podkop-subscription-maintenance-upgrade.sh"
 if sed -n '/^subscription_update() {/,/^}/p' "$work/runtime" | grep -q 'lock_acquire "speedtest"'; then
  echo 'FAIL: installer preserves or reintroduces speedtest self-lock into subscription_update'; exit 1
 fi
 test "$(sed -n '/^subscription_update() {/,/^}/p' "$work/runtime" | grep -c 'lock_acquire "subscription_update"')" = 1
 sh -n "$work/runtime"
done
echo 'PASS: upgrade repairs old self-lock and remains idempotent'
