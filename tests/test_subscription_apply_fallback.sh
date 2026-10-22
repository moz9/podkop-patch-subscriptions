#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export PODKOP_TEST_WORK="$work"
cat > "$work/receiver" <<'RECEIVER'
#!/bin/sh
set -eu
. "$PODKOP_TEST_WORK/guard"
[ "$*" = reload ]
[ "${PODKOP_SUBSCRIPTION_CACHE_ONLY:-0}" = 1 ]
[ "${PODKOP_SKIP_LIST_UPDATE:-0}" = 1 ]
config_foreach() { SNAPSHOT_HAS_REQUIRED=1; }
subscription_services_preflight() { printf 'preflight\n' >> "$PODKOP_TEST_WORK/events"; }
subscription_services_continuity_context_ready() {
    printf 'context:%s\n' "$PODKOP_TEST_PHASE" >> "$PODKOP_TEST_WORK/events"
    [ "$PODKOP_TEST_PHASE" = rollback ]
}
subscription_services_snapshot_continuity_prepare() {
    printf 'continuity\n' >> "$PODKOP_TEST_WORK/events"
    [ "$PODKOP_TEST_PHASE" = rollback ]
}
subscription_services_restart_prepare || exit 11
printf '%s:%s\n' "${PODKOP_SUBSCRIPTION_APPLY_NOW:-0}" "$PODKOP_SERVICE_RESTART_CONTINUITY" >> "$PODKOP_TEST_WORK/events"
RECEIVER
chmod +x "$work/receiver"
podkop_section_enabled() { return 1; }
for version in 0.7.20 0.7.22 0.7.23 0.7.24; do
    runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
    [ -f "$runtime" ] || continue
    sed -n '/^subscription_services_restart_prepare() {$/,/^}$/p' "$runtime" > "$work/guard"
    sed -n '/^subscription_apply_v2_reload() {$/,/^}$/p' "$runtime" |
        sed "s|/usr/bin/podkop|$work/receiver|g" > "$work/reload"
    if [ "${PODKOP_TEST_OLD_NATIVE_INTENT:-0}" = 1 ]; then
        sed 's/PODKOP_SUBSCRIPTION_APPLY_NOW="$apply_now" //g' "$work/reload" > "$work/old-reload"
        mv "$work/old-reload" "$work/reload"
    fi
    . "$work/reload"
    : > "$work/events"
    # Actual admission guard rejects an unmarked config change as continuity.
    if ! PODKOP_TEST_PHASE=apply PODKOP_SUBSCRIPTION_APPLY_NOW=0 subscription_apply_v2_reload; then
        grep -qx 'context:apply' "$work/events" || fail "$version test fixture failed before the real admission decision"
        fail "$version explicit Apply was passed to the continuity guard as a background reload"
    fi
    grep -qx '1:0' "$work/events" || fail "$version explicit intent was not passed to the native runtime"
    # A stale caller's Apply flag must not turn restoration into new admission.
    PODKOP_TEST_PHASE=rollback PODKOP_SECTION_ROLLBACK=1 PODKOP_SUBSCRIPTION_APPLY_NOW=1 subscription_apply_v2_reload
    [ "$(grep -c '^continuity$' "$work/events")" -eq 1 ] || fail "$version rollback bypassed continuity"
    grep -qx '0:1' "$work/events" || fail "$version rollback reused explicit-Apply authority"
    # Already patched installations must receive the corrected reload boundary.
    sed '/# subscription_apply_v2_native_intent_v1/d' "$runtime" > "$work/old-runtime"
    PODKOP_SOURCES_TARGET="$work/old-runtime" PODKOP_SOURCES_SOURCE="$runtime" \
        sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/upgrade-log"
    sed -n '/^subscription_apply_v2_reload() {$/,/^}$/p' "$runtime" > "$work/canonical-reload"
    sed -n '/^subscription_apply_v2_reload() {$/,/^}$/p' "$work/old-runtime" > "$work/delivered-reload"
    cmp -s "$work/canonical-reload" "$work/delivered-reload" || fail "$version existing-install retrofit retained the old reload boundary"
done
printf '%s\n' 'PASS: native Apply carries explicit intent; rollback keeps continuity and starts no extra engine'
