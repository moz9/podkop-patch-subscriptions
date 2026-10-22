#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime="$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
grep -q '^load_active_dns_settings() {' "$runtime"
sed -n '/^sing_box_configure_dns() {$/,/^}$/p' "$runtime" | grep -qx '    load_active_dns_settings'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
sed -n '/^load_active_dns_settings() {$/,/^}$/p' "$runtime" > "$work/dns"
. "$work/dns"
config_get() {
    case "$3" in
        dns_failover_active_slot) eval "$1=secondary";;
        secondary_dns_type) eval "$1=dot";;
        secondary_dns_server) eval "$1=\${secondary:-}";;
        secondary_bootstrap_dns_server) eval "$1=9.9.9.9";;
        *) eval "$1=\${4:-}";;
    esac
}
config_get_bool() { eval "$1=\$enabled"; }
log() { :; }
enabled=1; secondary=dns.example
load_active_dns_settings
[ "$ACTIVE_DNS_SLOT:$ACTIVE_DNS_TYPE:$ACTIVE_DNS_SERVER:$ACTIVE_BOOTSTRAP_DNS_SERVER" = secondary:dot:dns.example:9.9.9.9 ]
secondary=''
load_active_dns_settings
[ "$ACTIVE_DNS_SLOT:$ACTIVE_DNS_TYPE:$ACTIVE_DNS_SERVER" = primary:doh:1.1.1.1 ]
enabled=0; secondary=dns.example
load_active_dns_settings
[ "$ACTIVE_DNS_SLOT:$ACTIVE_DNS_TYPE:$ACTIVE_DNS_SERVER" = primary:doh:1.1.1.1 ]
# RouterDesk installs the canonical runtime without running incremental installers.
for spec in 'subscription_patch_update:update_start' 'get_subscription_patch_update_status:status'; do
    name=${spec%%:*}; command=${spec#*:}
    sed -n "/^$name() {$/,/^}/p" "$runtime" | grep -Fq "/usr/bin/podkop-update-manager $command"
done
for name in subscription_patch_update_check get_subscription_patch_update_log; do
    grep -qx "$name)" "$runtime"
done
if jq -e 'has("routerdeskPatch")' "$repo/openwrt/update-manifest.json" >/dev/null; then
    jq -e '.routerdeskPatch.initIntegration==1 and (.sha256["openwrt/podkop-subscription-sources-upgrade.sh"]|length)==64' "$repo/openwrt/update-manifest.json" >/dev/null
    jq -e '.releaseStatus=="released" and .routerdeskPatch.schemaVersion==1 and .routerdeskPatch.mode=="files-only" and (.routerdeskPatch.coordinatorSha256|test("^[a-f0-9]{64}$")) and (.routerdeskPatch.filesSha256|test("^[a-f0-9]{64}$"))' "$repo/openwrt/update-manifest.json" >/dev/null
fi
echo 'PASS: RouterDesk prebuilt runtime includes update-center entrypoints; migration remains gated'
