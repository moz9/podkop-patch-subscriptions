#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1 PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
. "$repo/openwrt/podkop-dns-optimizer"
facade=$(find "$repo/openwrt" -path '*/usr/lib/podkop/sing_box_config_facade.sh' | sort | tail -n 1)
eval "$(sed -n '/^sing_box_cf_add_dns_server() {$/,/^}$/p' "$facade")"
is_ipv4() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
eval "$(sed -n '/^dns_apply_pair() {$/,/^}$/p' "$repo/openwrt/podkop-dns-apply")"
SB_BOOTSTRAP_SERVER_TAG=bootstrap-dns-server
DA_WORK="$work"
fail() { echo "FAIL: $*" >&2; exit 1; }
url_get_host() { printf '%s\n' "$1" | cut -d/ -f1; }
url_get_port() { :; }
url_get_path() { case "$1" in */*) printf '/%s\n' "${1#*/}";; esac; }
for tuple in 'udp 223.6.6.6' 'tcp 1.1.1.1' 'doh cloudflare-dns.com' 'dot dns.google'; do
  set -- $tuple
  dns_apply_pair "$1" "$2" udp 45.90.28.0 || fail 'native pair construction'
  config=$(sing_box_cf_add_dns_server '{"dns":{"servers":[]}}' "$1" dns-server "$2" "" "")
  printf '%s' "$config" | jq -cS '.dns.servers[0]' > "$work/generated"
  jq -cS '.[0]' "$work/pair.json" > "$work/applied"
  cmp -s "$work/generated" "$work/applied" || fail "$tuple changes service evidence context on unchanged-DNS rebuild"
done
echo 'PASS: DNS-only application and normal runtime generation produce identical resolver definitions'
