#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for version in 0.7.20 0.7.22; do
    runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
    : > "$work/library"
    for name in subscription_reload_pending_file subscription_pending_sections_json subscription_pending_mark subscription_pending_clear get_subscription_operation_status; do
        grep -q "^$name() {" "$runtime" || fail "$version missing $name"
        sed -n "/^$name() {/,/^}/p" "$runtime" >> "$work/library"
    done
    . "$work/library"
    PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE="$work/pending"; export PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE
    podkop_section_enabled() { return 0; }
    podkop_section_single_mode() { return 1; }
    podkop_section_names() { echo '["main","GEOBLOCK"]'; }
    podkop_section_name() { echo main; }
    podkop_section_ready() { return 0; }
    subscription_runtime_busy() { return 1; }
    subscription_pending_mark main
    subscription_pending_mark GEOBLOCK
    subscription_pending_mark main
    subscription_pending_sections_json | jq -e '.==["GEOBLOCK","main"]' >/dev/null || fail 'union lost'
    subscription_pending_clear main
    get_subscription_operation_status | jq -e '.pending==true and .pendingSections==["GEOBLOCK"] and .isolatedReady==true' >/dev/null || fail 'peer pending lost from split-compatible status'
    podkop_section_single_mode() { return 0; }
    podkop_section_manager() { echo '{"ready":true,"sections":[{"section":"main","pid":101},{"section":"GEOBLOCK","pid":101}]}'; }
    get_subscription_operation_status | jq -e '.runtimeMode=="single" and .pendingSections==["GEOBLOCK"]' >/dev/null || fail 'single status lost peer pending'
    subscription_pending_clear GEOBLOCK
    [ ! -e "$work/pending" ] || fail 'empty pending retained'
    touch "$work/pending"
    subscription_pending_sections_json | jq -e '.==["main","GEOBLOCK"]' >/dev/null || fail 'old marker lost targets'
    podkop_section_enabled() { return 1; }
    subscription_pending_mark
    subscription_pending_clear
    [ ! -e "$work/pending" ] || fail 'non-section legacy marker compatibility broken'
    for pair in 'set_subscription_sections_enabled:subscription_pending_clear' 'subscription_update_section_handler:subscription_pending_mark' 'subscription_services_mark_pending:subscription_pending_mark'; do
        name="${pair%%:*}" action="${pair#*:}"
        sed -n "/^$name() [({]/,/^})\{0,1\}$/p" "$runtime" | grep -q "$action" || fail "$version $name missing scoped action"
    done
    # Simulate the old helper-less target while retaining all unrelated code.
    awk '/^subscription_pending_(sections_json|mark|clear)\(\) \{/ {skip=1;next} skip {if($0=="}")skip=0;next} {print}' "$runtime" > "$work/old-$version"
    printf '\ncustom_pending_sentinel() {\n    echo preserved\n}\n' >> "$work/old-$version"
    PODKOP_SOURCES_TARGET="$work/old-$version" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh"
    grep -q '^subscription_pending_clear() {' "$work/old-$version" || fail 'source updater skipped pending helpers'
    grep -q 'echo preserved' "$work/old-$version" || fail 'source updater lost custom function'
    cp "$work/old-$version" "$work/upgraded"
    PODKOP_SOURCES_TARGET="$work/old-$version" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh"
    cmp -s "$work/old-$version" "$work/upgraded" || fail 'source updater pending retrofit not idempotent'
done
echo 'PASS: legacy scoped pending union/clear, split and single status, old marker compatibility, custom-preserving idempotent delivery'
