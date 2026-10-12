#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source="$repo/openwrt/runtime-0.7.22/usr/bin/podkop"
[ ! -f "$repo/openwrt/runtime-0.7.23/usr/bin/podkop" ] || source="$repo/openwrt/runtime-0.7.23/usr/bin/podkop"
# Simulate a fully installed previous release whose source-controls upgrader
# would previously no-op despite the old local-ruleset preparation function.
awk '
/^prepare_source_ruleset\(\) {$/ {print "prepare_source_ruleset() {\n    :\n}"; skip=1;next}
skip {if($0=="}")skip=0;next}
{print}
' "$source" > "$work/target"
PODKOP_SOURCES_SOURCE="$source" PODKOP_SOURCES_TARGET="$work/target"     sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
sed -n '/^prepare_source_ruleset() {$/,/^}$/p' "$source" > "$work/expected"
sed -n '/^prepare_source_ruleset() {$/,/^}$/p' "$work/target" > "$work/actual"
cmp -s "$work/actual" "$work/expected" || fail 'existing release did not receive source-ruleset fix'
grep -Fqx '# subscription_source_ruleset_reuse_v1' "$work/target" || fail 'delivered reuse capability marker missing'
cp "$work/target" "$work/first"
PODKOP_SOURCES_SOURCE="$source" PODKOP_SOURCES_TARGET="$work/target"     sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
cmp -s "$work/target" "$work/first" || fail 'second upgrade is not idempotent'
for installer in "$repo/i" "$repo/openwrt/install.sh"; do
    [ "$(grep -Fc '# subscription_source_ruleset_reuse_v1' "$installer")" -ge 2 ] || fail 'installer no-op/upgrade capability gates missing'
done
printf 'PASS: source ruleset fix is delivered to existing releases idempotently\n'
