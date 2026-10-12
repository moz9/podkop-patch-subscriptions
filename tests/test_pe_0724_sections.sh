#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
old="$repo/openwrt/runtime-0.7.23/usr/bin/podkop"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
grep -q '^subscription_pending_sections_json() {' "$runtime" || fail 'section-aware pending state is absent'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
extract() { sed -n "/^$1() /,/^[})]$/p" "$2"; }
for name in subscription_cas_shared_clean subscription_reload_pending_file subscription_pending_sections_json subscription_pending_mark subscription_pending_clear get_subscription_operation_status subscription_services_snapshot_hash subscription_apply_v2_reload; do
    extract "$name" "$runtime" >> "$work/functions"
done
. "$work/functions"
PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE="$work/pending"
enabled=1
podkop_section_enabled() { [ "$enabled" = 1 ]; }
podkop_section_names() { printf '["first","second"]\n'; }
podkop_section_name() { printf 'first\n'; }
podkop_section_manager() { printf '%s\n' "$manager_status"; }
subscription_runtime_busy() { return 1; }
# This reload-only fixture has no unsaved shared UCI delta.
uci() {
    [ "$1" != -q ] || shift
    [ "$1" = changes ] && [ "$2" = podkop ]
}
podkop_section_apply() { printf '%s' "${PODKOP_SECTION_ROLLBACK:-0}" > "$work/apply"; }
podkop_section_runtime_hash() { printf '%064d\n' 42; }
config_get() { eval "$1=\$work/config.json"; }
subscription_pending_sections_json | jq -e '.==[]' >/dev/null
subscription_pending_mark first
subscription_pending_mark second
subscription_pending_mark first
subscription_pending_sections_json | jq -e '.==["first","second"]' >/dev/null || fail 'pending section union lost'
subscription_pending_clear first
subscription_pending_sections_json | jq -e '.==["second"]' >/dev/null || fail 'clearing one section cleared another'
manager_status='{"ready":true,"sections":[{"section":"first","ready":true},{"section":"second","ready":true}]}'
get_subscription_operation_status | jq -e '.pending==true and .pendingSections==["second"] and .isolatedSections==["first","second"] and .isolatedReady==true' >/dev/null || fail 'multi-section operation status lost'
manager_status='{"ready":true,"sections":[{"section":"first","ready":true}]}'
get_subscription_operation_status | jq -e '.isolatedReady==false' >/dev/null || fail 'incomplete registry reported ready'
subscription_pending_clear second
[ ! -e "$work/pending" ] || fail 'empty pending file retained'
touch "$work/pending"
subscription_pending_sections_json | jq -e '.==["first","second"]' >/dev/null || fail 'legacy marker lost registered targets'
enabled=0
subscription_pending_mark
subscription_pending_clear
[ ! -e "$work/pending" ] || fail 'legacy nonsection pending clear regressed'
enabled=1
PODKOP_SECTION_ROLLBACK=1 subscription_apply_v2_reload
[ "$(cat "$work/apply")" = 1 ] || fail 'isolated rollback context not propagated'
printf '{}\n' > "$work/config.json"
[ "$(subscription_services_snapshot_hash "$work/config.json")" = "$(printf '%064d' 42)" ] || fail 'section runtime hash adapter missing'
printf 'rules\n' > "$work/list.json"
[ "$(subscription_services_snapshot_hash "$work/list.json")" = "$(sha256sum "$work/list.json"|cut -d ' ' -f1)" ] || fail 'rule file hashing altered'

# Critical newer admission/continuity logic must remain byte-identical to .23.
for name in subscription_source_policy subscription_services_read subscription_services_store subscription_services_classify subscription_gemini_region_policy subscription_services_snapshot_capacity subscription_services_snapshot_continuity_section subscription_services_snapshot_restore_rules subscription_action_lock_pid_alive subscription_action_legacy_lock_busy subscription_action_lock_busy subscription_action_lock_acquire subscription_action_lock_release subscription_speedtest_start subscription_speedtest_stop; do
    extract "$name" "$runtime" > "$work/new"
    extract "$name" "$old" > "$work/old"
    cmp "$work/new" "$work/old" || fail "newer safety logic overwritten: $name"
done
# Scoped admission intentionally extends .23: last-requirement removal has an
# empty admission, and new rows record their exact required-service basis. The
# maintained helper, not the archived runtime, is authoritative for this block.
sed -n '/^# subscription_service_snapshot_v1 begin$/,/^# subscription_service_snapshot_v1 end$/p' "$runtime" > "$work/snapshot"
cmp "$work/snapshot" "$repo/openwrt/podkop-service-snapshot.sh" || fail 'canonical snapshot helper/runtime drift'
# Cancellation/worker code is unchanged; only its config source becomes logical.
extract subscription_isolated_test "$runtime" | sed '/^    config=.*probe_error dns_config_invalid$/c\    # config source' > "$work/new"
extract subscription_isolated_test "$old" | sed '/^    config=.*probe_error dns_config_invalid$/c\    # config source' > "$work/old"
cmp "$work/new" "$work/old" || fail 'isolated cancellation/worker guards overwritten'
for name in subscription_probe_config subscription_isolated_test; do
    extract "$name" "$runtime" > "$work/new"
    extract "$name" "$repo/openwrt/podkop-subscription-probe.sh" > "$work/helper"
    cmp "$work/new" "$work/helper" || fail "embedded/helper drift: $name"
done
for expectation in \
    'start_main|podkop-section-worker restart' \
    'start_main|podkop-section-runtime wait-ready' \
    'stop_main|podkop-section-worker stop' \
    'subscription_apply_v2_restore|PODKOP_SECTION_ROLLBACK=1' \
    'set_subscription_sections_enabled|podkop_section_preflight' \
    'set_subscription_sections_enabled|subscription_pending_clear' \
    'subscription_reload_seamless|podkop_section_apply' \
    'subscription_update_section_handler|subscription_pending_mark' \
    'subscription_update|podkop_section_preflight' \
    'subscription_isolated_test|podkop_section_logical_path' \
    'subscription_services_mark_pending|subscription_pending_mark' \
    'sing_box_save_config|podkop_section_bootstrap' \
    'clash_api|podkop_section_api_url' \
    'clash_api|podkop_section_api_merge'; do
    name="${expectation%%|*}"; fragment="${expectation#*|}"
    extract "$name" "$runtime" | grep -Fq "$fragment" || fail "missing lifecycle seam: $name / $fragment"
done
extract start_main "$runtime" | grep -Fq 'subscription_services_snapshot_continuity_prepare' || fail 'newer startup continuity guard replaced'
extract sing_box_init_config "$runtime" | grep -Fq 'subscription_services_snapshot_continuity_prepare' || fail 'newer generation continuity guard replaced'
grep -Fq 'section-hooks.sh' "$runtime" || fail 'section hooks loader missing'
grep -Fq 'section_isolation_unavailable' "$runtime" || fail 'missing hooks not fail-closed'
extract subscription_isolated_test "$repo/openwrt/podkop-subscription-probe.sh" | grep -Fq 'podkop_section_logical_path' || fail 'helper probe reads gateway instead of logical runtime'
printf 'PASS: PE 0.7.24 section pending/status/hash/lifecycle hooks and newer admission guards\n'
