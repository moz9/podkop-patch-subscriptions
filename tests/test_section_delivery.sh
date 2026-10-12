#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM
sh -n "$repo_root/i"
sh -n "$repo_root/openwrt/install.sh"
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo_root/i" > "$test_root/installer.sh"
. "$test_root/installer.sh"
for rel in usr/bin/podkop-section-runtime etc/init.d/podkop-section-worker usr/lib/podkop/section-hooks.sh; do
  printf '%s\n' "$RUNTIME_FILES" | grep -Fxq "$rel" || { echo "FAIL: section asset missing from rollback: $rel" >&2; exit 1; }
done
command -v install_section_runtime_assets >/dev/null || { echo 'FAIL: installer drops section assets' >&2; exit 1; }
sed -n '/^section_runtime_assets_current() {$/,/^}$/p' "$repo_root/i" | grep -Fq 'subscription_isolated_section=/d' || { echo 'FAIL: installer noop ignores old service-proof context' >&2; exit 1; }
SECTION_INSTALL_ROOT="$test_root/root"
tmp_dir="$repo_root/openwrt"
mkdir -p "$SECTION_INSTALL_ROOT/usr/bin"
cp "$repo_root/openwrt/runtime-0.7.22/usr/bin/podkop" "$SECTION_INSTALL_ROOT/usr/bin/podkop"
install_section_runtime_assets
cmp "$repo_root/openwrt/podkop-section-runtime" "$SECTION_INSTALL_ROOT/usr/bin/podkop-section-runtime"
cmp "$repo_root/openwrt/podkop-section-worker.init" "$SECTION_INSTALL_ROOT/etc/init.d/podkop-section-worker"
cmp "$repo_root/openwrt/podkop-section-hooks.sh" "$SECTION_INSTALL_ROOT/usr/lib/podkop/section-hooks.sh"
[ ! -e "$SECTION_INSTALL_ROOT/etc/rc.d" ]
for version in 0.7.20 0.7.22; do
  cp "$repo_root/openwrt/runtime-$version/usr/bin/podkop" "$test_root/podkop-$version"
  # Reconstruct known pre-CAS contexts only in this temporary historical fixture.
  # Keep the published section patch immutable and reject unexpected drift.
  node "$repo_root/tests/section-historical-context.mjs" "$test_root/podkop-$version"
  patch --batch --reverse --fuzz=0 "$test_root/podkop-$version" < "$repo_root/openwrt/podkop-section-runtime-upgrade.patch"
  sed -i 's/; \/\^podkop.settings.subscription_isolated_section=\/d//' "$test_root/podkop-$version"
  printf '\ncustom_user_function() {\n    echo preserved\n}\n' >> "$test_root/podkop-$version"
  # A normal source upgrade can already replace only some integration sites.
  sed -i '/^# subscription_game_filter_v1$/d' "$test_root/podkop-$version"
  PODKOP_SOURCES_TARGET="$test_root/podkop-$version" PODKOP_SOURCES_SOURCE="$repo_root/openwrt/runtime-$version/usr/bin/podkop" \
    sh "$repo_root/openwrt/podkop-subscription-sources-upgrade.sh"
  sed -i 's/; \/\^podkop.settings.subscription_isolated_section=\/d//' "$test_root/podkop-$version"
  PODKOP_SECTION_UPGRADE_VERSION="$version" PODKOP_SECTION_UPGRADE_TARGET="$test_root/podkop-$version" PODKOP_SECTION_UPGRADE_BACKUP="$test_root/backup-$version" \
    sh "$repo_root/openwrt/podkop-section-upgrade.sh"
  grep -q 'podkop_section_bootstrap' "$test_root/podkop-$version"
  sed -n '/^subscription_services_context() {$/,/^}$/p' "$test_root/podkop-$version" | grep -Fq '/^podkop.settings.subscription_isolated_section=/d' || { echo 'FAIL: delivered runtime invalidates service proof on isolation opt-in' >&2; exit 1; }
  grep -q 'echo preserved' "$test_root/podkop-$version"
  sh -n "$test_root/podkop-$version"
  cp "$test_root/podkop-$version" "$test_root/complete-$version"
  PODKOP_SECTION_UPGRADE_VERSION="$version" PODKOP_SECTION_UPGRADE_TARGET="$test_root/podkop-$version" PODKOP_SECTION_UPGRADE_BACKUP="$test_root/backup-$version" \
    sh "$repo_root/openwrt/podkop-section-upgrade.sh"
  cmp "$test_root/complete-$version" "$test_root/podkop-$version"
done
# Unsupported generations and unrecognized context drift must not mutate a runtime.
cp "$test_root/backup-0.7.22" "$test_root/unsupported"
if PODKOP_SECTION_UPGRADE_VERSION=0.8.0 PODKOP_SECTION_UPGRADE_TARGET="$test_root/unsupported" sh "$repo_root/openwrt/podkop-section-upgrade.sh"; then exit 1; fi
cmp "$test_root/backup-0.7.22" "$test_root/unsupported"
cp "$test_root/backup-0.7.22" "$test_root/drifted"
sed -i 's/log "Save sing-box temporary config to /log "Custom sing-box config /' "$test_root/drifted"
cp "$test_root/drifted" "$test_root/drifted-before"
if PODKOP_SECTION_UPGRADE_VERSION=0.7.22 PODKOP_SECTION_UPGRADE_TARGET="$test_root/drifted" sh "$repo_root/openwrt/podkop-section-upgrade.sh"; then exit 1; fi
cmp "$test_root/drifted" "$test_root/drifted-before"
# The modern context repair recognizes only the exact CAS reader and DNS seam.
# Unknown custom edits must still refuse, without creating a backup or mutation.
for drift in cas-reader dns-context; do
  cp "$test_root/backup-0.7.22" "$test_root/$drift"
  case "$drift" in
    cas-reader) sed -i '/^subscription_services_context() {$/,/^}$/s/subscription_cas_settings/custom_cas_settings/g' "$test_root/$drift" ;;
    dns-context) sed -i '/^subscription_services_context() {$/,/^}$/s/dns="$(jq -ceS/dns="$(jq -cSe/' "$test_root/$drift" ;;
  esac
  cp "$test_root/$drift" "$test_root/$drift-before"
  if PODKOP_SECTION_UPGRADE_VERSION=0.7.22 PODKOP_SECTION_UPGRADE_TARGET="$test_root/$drift" PODKOP_SECTION_UPGRADE_BACKUP="$test_root/$drift-backup" \
    sh "$repo_root/openwrt/podkop-section-upgrade.sh"; then exit 1; fi
  cmp "$test_root/$drift" "$test_root/$drift-before"
  [ ! -e "$test_root/$drift-backup" ]
done
cmp "$repo_root/i" "$repo_root/openwrt/install.sh"
printf '%s\n' 'PASS: section assets installed without opt-in, backed up, custom runtime upgraded without replacement'
