#!/bin/sh
set -eu
target="${PODKOP_SOURCES_TARGET:-/usr/bin/podkop}"
source_runtime="${PODKOP_SOURCES_SOURCE:?canonical runtime is required}"
work="$(mktemp -d /tmp/podkop-sources-upgrade.XXXXXX)"
staged="${target}.sources.$$"
trap 'rm -rf "$work"; rm -f "$staged"' EXIT INT TERM HUP
[ -f "$target" ] && [ -f "$source_runtime" ]
sh -n "$source_runtime"
if grep -Fqx '# subscription_sources_v1 begin' "$target" && grep -Fqx '# subscription_isolated_probe_v1 end' "$target"; then
    echo 'Subscription source controls are already installed.'
    exit 0
fi
for block in subscription_sources_v1 subscription_isolated_probe_v1; do
    sed -n "/^# $block begin$/,/^# $block end$/p" "$source_runtime" > "$work/$block"
    [ -s "$work/$block" ]
done
names='append_subscription_item filter_working_subscription_proxy_links refresh_subscription_cache load_subscription_proxy_links_for_section apply_subscription_exclusions_to_cached_links set_subscription_sections_enabled subscription_speedtest_stop'
for name in $names; do
    sed -n "/^$name() {$/,/^}$/p" "$source_runtime" > "$work/$name"
    [ -s "$work/$name" ]
    grep -q "^$name() {" "$target"
done
awk -v dir="$work" -v names="$names" '
BEGIN { n=split(names,a," "); for(i=1;i<=n;i++) replace[a[i]"() {"]=a[i] }
function emit(path, line) { while ((getline line < path)>0) print line; close(path) }
skipping { if($0=="}") skipping=0; next }
$0=="append_subscription_item() {" { emit(dir"/subscription_sources_v1"); emit(dir"/subscription_isolated_probe_v1") }
$0 in replace { emit(dir"/"replace[$0]); skipping=1; next }
$0=="subscription_speedtest() {" { skipping=1; next }
$0=="get_subscription_items_cached)" { print "get_subscription_sources)\n    get_subscription_sources \"$2\"\n    ;;" }
$0=="subscription_speedtest)" { print "subscription_ping)\n    subscription_ping \"$2\" \"$3\"\n    ;;" }
{ print }
' "$target" > "$staged"
sh -n "$staged"
[ "$(grep -c '^subscription_speedtest() {' "$staged")" -eq 1 ]
[ "$(grep -c '^get_subscription_sources)' "$staged")" -eq 1 ]
backup="${PODKOP_SOURCES_BACKUP:-${target}.before-sources}"
[ -e "$backup" ] || cp -p "$target" "$backup"
chmod 755 "$staged"
mv "$staged" "$target"
echo 'Installed subscription source controls and isolated diagnostics.'
