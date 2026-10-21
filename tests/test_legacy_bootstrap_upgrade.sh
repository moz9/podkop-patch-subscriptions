#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
for version in 0.7.20 0.7.22; do
 cp "$root/openwrt/runtime-$version/usr/bin/podkop" "$work/runtime"
 PODKOP_DNS_FAILOVER_TARGET="$work/runtime" PODKOP_DNS_FAILOVER_SHELL=sh sh "$root/openwrt/podkop-dns-failover-upgrade.sh"
 sed -n '/^load_active_dns_settings() {/,/^}/p' "$work/runtime" > "$work/function"
 config_get() {
  case "$3" in
    dns_type) value=dot;; dns_server) value=cloudflare-dns.com;; bootstrap_dns_type) value=tcp;; bootstrap_dns_server) value=77.88.8.8;;
    dns_failover_active_slot) value="$slot";; secondary_dns_type) value=doh;; secondary_dns_server) value=dns.google;; secondary_bootstrap_dns_type) value=dot;; secondary_bootstrap_dns_server) value=9.9.9.9;;
    *) value="${4:-}";;
  esac
  eval "$1=\$value"
 }
 config_get_bool() { eval "$1=1"; }
 log() { :; }
 . "$work/function"
 slot=primary; load_active_dns_settings
 [ "${ACTIVE_BOOTSTRAP_DNS_TYPE:-}" = tcp ] || { echo 'FAIL: primary bootstrap protocol lost during rebuild'; exit 1; }
 slot=secondary; load_active_dns_settings
 [ "${ACTIVE_BOOTSTRAP_DNS_TYPE:-}" = dot ] || { echo 'FAIL: reserve bootstrap protocol lost during rebuild'; exit 1; }
 grep -Fq 'sing_box_cf_add_dns_server "$config" "$bootstrap_dns_type"' "$work/runtime"
 cp "$work/runtime" "$work/once"
 PODKOP_DNS_FAILOVER_TARGET="$work/runtime" PODKOP_DNS_FAILOVER_SHELL=sh sh "$root/openwrt/podkop-dns-failover-upgrade.sh"
 cmp "$work/once" "$work/runtime"
done
echo 'PASS: legacy primary/reserve bootstrap protocols survive rebuild and idempotent upgrade'
