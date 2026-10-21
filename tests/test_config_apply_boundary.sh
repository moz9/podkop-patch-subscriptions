#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-snapshot.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_CONFIG_APPLY_STAMP="$work/applied"
subscription_runtime_busy() { [ "${busy:-0}" = 1 ]; }
subscription_action_lock_acquire() { echo lock >> "$work/events"; }
subscription_action_lock_release() { echo unlock >> "$work/events"; }
subscription_services_snapshot_policy_hash() { printf '%s\n' "${policy:-one}"; }
uci() { [ "${draft:-0}" = 0 ] || echo 'podkop.main.user_domains=draft'; }
log() { :; }
restart() {
    [ "${PODKOP_SUBSCRIPTION_APPLY_NOW:-0}" = 1 ] || fail 'config apply lacked explicit admission gate'
    [ "${PODKOP_SUBSCRIPTION_CACHE_ONLY:-0}" = 1 ] || fail 'config apply downloads subscriptions'
    echo restart >> "$work/events"
    [ "${reject:-0}" = 0 ]
}
subscription_config_apply || fail 'committed config apply failed'
[ "$(grep -c '^restart$' "$work/events")" = 1 ] || fail 'config event did not apply'
subscription_config_apply || fail 'duplicate config event failed'
[ "$(grep -c '^restart$' "$work/events")" = 1 ] || fail 'duplicate event restarted engine'
[ "${PODKOP_SUBSCRIPTION_APPLY_NOW:-0}" = 0 ] || fail 'apply permission leaked'
policy=two; reject=1
! subscription_config_apply || fail 'failed admission reported success'
[ "$(cat "$work/applied")" = one ] || fail 'failed apply advanced stamp'
reject=0; draft=1
! subscription_config_apply || fail 'foreign draft accepted'
draft=0; busy=1
! subscription_config_apply || fail 'concurrent operation accepted'
echo 'PASS: committed apply is explicit, locked, cache-only, deduplicated and preserves refusal'

# Exercise the coordinator together with the real lifecycle gate, not merely
# a fake restart that happens to return an error.
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    (
        export PODKOP_CONFIG_APPLY_STAMP="$work/real-applied"
        rm -f "$work/real-applied" "$work/stopped"
        busy=0; draft=0
        config_foreach() { "$1" main; }
        validate_subscription_urltest_section() { return 0; }
        subscription_required_services_json() { echo '["gemini"]'; }
        subscription_services_preflight() { return 1; }
        stop() { touch "$work/stopped"; }
        start() { fail 'unadmitted config reached start'; }
        eval "$(sed -n '/^restart() {$/,/^}$/p' "$runtime")"
        ! subscription_config_apply || fail 'real lifecycle accepted invalid evidence'
        [ ! -e "$work/stopped" ] || fail 'real lifecycle stopped the working runtime on invalid evidence'
    )
done
echo 'PASS: real lifecycle keeps the running service when config-apply admission fails'
