#!/bin/sh
set -eu
target="${PODKOP_SECTION_UPGRADE_TARGET:-/usr/bin/podkop}"
patch_file="${PODKOP_SECTION_UPGRADE_PATCH:-$(dirname "$0")/podkop-section-runtime-upgrade.patch}"
version="${PODKOP_SECTION_UPGRADE_VERSION:-$($target show_version 2>/dev/null | sed 's/^v//' | head -n 1)}"
case "$version" in 0.7.19|0.7.20|0.7.21|0.7.22) ;; *) echo 'Unsupported section runtime upgrade version' >&2; exit 1;; esac
[ -f "$target" ] && [ ! -L "$target" ] || exit 1
section_integration_complete() {
  grep -Fq '. /usr/lib/podkop/section-hooks.sh' "$1" || return 1
  for site in 'start_main:podkop-section-worker restart' 'stop_main:podkop-section-worker stop' \
    'get_subscription_operation_status:isolatedReady' 'subscription_apply_v2_reload:podkop_section_apply' \
    'subscription_apply_v2_restore:PODKOP_SECTION_ROLLBACK=1' 'set_subscription_sections_enabled:podkop_section_preflight' \
    'subscription_sing_box_pid:ubus call service list' 'subscription_reload_seamless:podkop_section_apply' \
    'subscription_isolated_test:podkop_section_logical_path' 'subscription_services_snapshot_hash:podkop_section_runtime_hash' \
    'subscription_services_context:/^podkop.settings.subscription_isolated_section=/d' \
    'sing_box_save_config:podkop_section_bootstrap' 'clash_api:podkop_section_api_merge' 'clash_api:podkop_section_api_url'; do
    name="${site%%:*}"
    pattern="${site#*:}"
    sed -n "/^$name() {$/,/^}$/p" "$1" | grep -Fq "$pattern" || return 1
  done
}
if section_integration_complete "$target"; then
  echo 'Section runtime integration already installed.'
  exit 0
fi
tmp="$(mktemp -d)"
staged_target="${target}.section-upgrade.$$"
trap 'rm -rf "$tmp"; rm -f "$staged_target"' EXIT INT TERM HUP
cp -p "$target" "$tmp/podkop"
# Patch only the integration sites. Unknown custom drift fails without modifying target.
# The services block can move during source upgrades; apply its context hunk
# independently so patch's ordered hunk search cannot miss a relocated function.
awk '/^--- / || /^\+\+\+ / {print; next} /^@@/ {active=index($0,"subscription_services_context()")>0} active {print}' \
  "$patch_file" > "$tmp/context.patch"
patch --batch --forward --fuzz=0 "$tmp/podkop" < "$tmp/context.patch" > "$tmp/context.log" 2>&1 || true
# Source retrofit now reads settings through the committed-only CAS adapter.
# Derive one alternative context hunk without changing the historical patch:
# all other original context lines still have to match exactly (zero fuzz).
awk '
$0 == "     settings=\"$(uci -q show podkop.settings)\" || return 1" {
    print "     settings=\"$(if command -v subscription_cas_settings >/dev/null; then subscription_cas_settings; else uci -q show podkop.settings; fi)\" || return 1"
    next
}
{print}
' "$tmp/context.patch" > "$tmp/cas-context.patch"
patch --batch --forward --fuzz=0 "$tmp/podkop" < "$tmp/cas-context.patch" > "$tmp/cas-context.log" 2>&1 || true
patch --batch --forward --fuzz=0 "$tmp/podkop" < "$patch_file" > "$tmp/patch.log" 2>&1 || true
# Source/apply/seamless maintenance may already have installed individual hunks.
# Accept skipped hunks only when every integration site is present afterwards.
if ! section_integration_complete "$tmp/podkop"; then
  cat "$tmp/patch.log" >&2
  echo 'Incomplete section integration; target unchanged' >&2
  exit 1
fi
sh -n "$tmp/podkop"
backup="${PODKOP_SECTION_UPGRADE_BACKUP:-/root/podkop-section-backup-$(date +%Y%m%d-%H%M%S)-$$}"
[ ! -e "$backup" ] || { echo 'Section upgrade backup already exists' >&2; exit 1; }
cp -p "$target" "$backup"
cp "$tmp/podkop" "$staged_target"
chmod 755 "$staged_target"
mv "$staged_target" "$target"
echo "Section runtime integration installed; backup: $backup"
