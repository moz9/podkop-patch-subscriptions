#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM
for version in 0.7.20 0.7.22; do
    sed -n '/^# subscription_seamless_reload begin$/,/^# subscription_seamless_reload end$/p' \
        "$repo_root/openwrt/runtime-$version/usr/bin/podkop" > "$test_root/block"
    . "$test_root/block"
    PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE="$test_root/pending"
    unset PODKOP_SUBSCRIPTION_APPLY_NOW
    config_get() { eval "$1=\$test_root/config"; }
    log() { :; }
    echolog() { :; }
    sing_box_init_config() { echo touched > "$test_root/unsafe"; }
    subscription_signal_sing_box_reload() { echo signalled > "$test_root/unsafe"; }
    echo stable > "$test_root/config"
    subscription_reload_seamless || { echo 'FAIL: refresh should defer successfully'; exit 1; }
    [ ! -e "$test_root/unsafe" ] || { echo 'FAIL: default refresh touched running configuration'; exit 1; }
    [ -f "$test_root/pending" ] || { echo 'FAIL: pending update missing'; exit 1; }
    subscription_reload_seamless
    [ ! -e "$test_root/unsafe" ] || { echo 'FAIL: pending retry applied automatically'; exit 1; }
done
echo 'PASS: background subscription refresh and retries never apply configuration'
