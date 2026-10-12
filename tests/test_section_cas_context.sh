#!/bin/sh
set -eu
repo=${1:-$(cd "$(dirname "$0")/.." && pwd)}
work=$(mktemp -d /tmp/podkop-section-cas-XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM HUP
upgrader=$repo/openwrt/podkop-section-upgrade.sh
patchfile=$repo/openwrt/podkop-section-runtime-upgrade.patch
runtime=$repo/openwrt/runtime-0.7.22/usr/bin/podkop
sed 's@; /\^podkop.settings.subscription_isolated_section=/d@@' "$runtime" > "$work/partial"
printf '\ncustom_kept() {\n    echo custom-preserved\n}\n' >> "$work/partial"
cp "$work/partial" "$work/target"
PODKOP_SECTION_UPGRADE_TARGET="$work/target" PODKOP_SECTION_UPGRADE_VERSION=0.7.22 PODKOP_SECTION_UPGRADE_PATCH="$patchfile" PODKOP_SECTION_UPGRADE_BACKUP="$work/backup" sh "$upgrader" > "$work/positive.log" 2>&1
cmp "$work/backup" "$work/partial"
sed -n '/^subscription_services_context() {$/,/^}$/p' "$work/target" | grep -Fq 'subscription_cas_settings'
sed -n '/^subscription_services_context() {$/,/^}$/p' "$work/target" | grep -Fq '/^podkop.settings.subscription_isolated_section=/d'
grep -Fq 'echo custom-preserved' "$work/target"
cp "$work/target" "$work/once"
PODKOP_SECTION_UPGRADE_TARGET="$work/target" PODKOP_SECTION_UPGRADE_VERSION=0.7.22 PODKOP_SECTION_UPGRADE_PATCH="$patchfile" PODKOP_SECTION_UPGRADE_BACKUP="$work/never-created" sh "$upgrader" > "$work/repeat.log" 2>&1
cmp "$work/target" "$work/once"
[ ! -e "$work/never-created" ]
for drift in reader dns; do
 case "$drift" in
 reader) sed 's/command -v subscription_cas_settings >\/dev\/null/command -v custom_cas_settings >\/dev\/null/' "$work/partial" > "$work/target";;
 dns) sed 's@/etc/sing-box/config.json)@/etc/sing-box/custom.json)@' "$work/partial" > "$work/target";;
 esac
 cp "$work/target" "$work/drift-before"
 if PODKOP_SECTION_UPGRADE_TARGET="$work/target" PODKOP_SECTION_UPGRADE_VERSION=0.7.22 PODKOP_SECTION_UPGRADE_PATCH="$patchfile" PODKOP_SECTION_UPGRADE_BACKUP="$work/drift-backup" sh "$upgrader" > "$work/drift.log" 2>&1; then
  echo "FAIL unknown $drift drift accepted" >&2; exit 1
 fi
 cmp "$work/target" "$work/drift-before"
 [ ! -e "$work/drift-backup" ]
done
echo 'PASS recognized CAS-context retrofit, custom preservation, backup, idempotence and unknown-context refusal'
