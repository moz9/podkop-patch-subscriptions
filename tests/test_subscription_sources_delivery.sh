#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
for version in 0.7.20 0.7.22; do
    source="$repo/openwrt/runtime-$version/usr/bin/podkop"
    sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$source" > "$work/sources"
    sed -n '/^# subscription_isolated_probe_v1 begin$/,/^# subscription_isolated_probe_v1 end$/p' "$source" > "$work/probe"
    cmp -s "$work/sources" "$repo/openwrt/podkop-subscription-sources.sh"
    cmp -s "$work/probe" "$repo/openwrt/podkop-subscription-probe.sh"
    target="$work/podkop-$version"
    awk '
    /^# subscription_sources_v1 begin$|^# subscription_isolated_probe_v1 begin$/ {skip=1;next}
    /^# subscription_sources_v1 end$|^# subscription_isolated_probe_v1 end$/ {skip=0;next}
    skip {next}
    /^get_subscription_sources\)$|^subscription_ping\)$/ {skip_case=1;next}
    skip_case {if($0 ~ /;;/)skip_case=0;next}
    {print}
    ' "$source" > "$target"
    printf '\nsubscription_speedtest() {\n    :\n}\n' >> "$target"
    PODKOP_SOURCES_TARGET="$target" PODKOP_SOURCES_SOURCE="$source" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    sh -n "$target"
    [ "$(grep -c '^subscription_speedtest() {' "$target")" -eq 1 ]
    [ "$(grep -c '^get_subscription_sources)' "$target")" -eq 1 ]
    [ "$(grep -c '^# subscription_sources_v1 begin' "$target")" -eq 1 ]
    [ -s "$target.before-sources" ]
    cp "$target" "$work/first"
    PODKOP_SOURCES_TARGET="$target" PODKOP_SOURCES_SOURCE="$source" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    cmp -s "$target" "$work/first"
done
grep -Fq 'download "$RAW_BASE/$SOURCES_UPGRADE_FILE"' "$repo/i"
grep -Fq 'PODKOP_SOURCES_SOURCE="$tmp_dir/podkop.runtime-0.7.20"' "$repo/i"
echo 'PASS: existing runtime upgrade, backup, idempotence and installer delivery'
