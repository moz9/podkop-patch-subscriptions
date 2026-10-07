#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1 PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
. "$repo/openwrt/podkop-dns-optimizer"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ "$(normalize_benchmark_protocols udp,tcp,doh,dot)" = 'udp tcp doh dot' ] || fail 'four supported DNS protocols'
for protocol in doq h3; do
  if normalize_benchmark_protocols "$protocol"; then fail "unsupported engine protocol accepted: $protocol"; fi
done
endpoint="$(dns_catalog_endpoint dot cloudflare-dns.com)" || fail 'catalog endpoint lookup'
printf '%s' "$endpoint" | jq -e '.host=="one.one.one.one" and .port==853' >/dev/null || fail 'catalog host must override value'
endpoint="$(dns_catalog_endpoint doh 9.9.9.9 bootstrap)" || fail 'bootstrap endpoint lookup'
printf '%s' "$endpoint" | jq -e '.host=="9.9.9.9" and .server_name=="dns.quad9.net"' >/dev/null || fail 'bootstrap IP/SNI metadata'
uci() { case "$*" in *dns_optimizer_candidates*) echo '223_5_5_5 google yandex';; *dns_optimizer_include_current*|*dns_optimizer_include_wan*) echo 0;; *) return 1;; esac; }
write_main_candidates tcp "$work/candidates"
grep -q '223.5.5.5' "$work/candidates" || fail 'AliDNS candidate absent'
if grep -qi yandex "$work/candidates"; then fail 'Yandex normal upstream exclusion changed'; fi
sed -n '/^sing_box_cf_add_dns_server() {/,/^}/p' "$repo/openwrt/runtime-0.7.23/usr/lib/podkop/sing_box_config_facade.sh" > "$work/facade"
. "$work/facade"
url_get_host() { candidate_host "$1"; }
url_get_port() { echo ''; }
url_get_path() { candidate_path "$1"; }
log() { echo "$*" >&2; }
for protocol in udp tcp doh dot; do
  config="$(sing_box_cf_add_dns_server '{"dns":{"servers":[]}}' "$protocol" bootstrap 9.9.9.9 '' '')" || fail "$protocol bootstrap generation"
  expected_type="$protocol"; case "$protocol" in doh) expected_type=https;; dot) expected_type=tls;; esac
  printf '%s' "$config" | jq -e --arg type "$expected_type" '.dns.servers[0].type==$type and .dns.servers[0].server=="9.9.9.9" and (.dns.servers[0].domain_resolver|not)' >/dev/null || fail "$protocol bootstrap circular or wrong IP"
  case "$protocol" in doh|dot) printf '%s' "$config" | jq -e '.dns.servers[0].tls.server_name=="dns.quad9.net"' >/dev/null || fail 'bootstrap SNI omitted';; esac
done
config="$(sing_box_cf_add_dns_server '{"dns":{"servers":[]}}' dot main cloudflare-dns.com '' '')"
printf '%s' "$config" | jq -e '.dns.servers[0].server=="one.one.one.one" and .dns.servers[0].domain_resolver=="bootstrap"' >/dev/null || fail 'runtime alias host/bootstrap resolution'
config="$(sing_box_cf_add_dns_server '{"dns":{"servers":[]}}' doh main freedns.controld.com/p0 '' '')"
printf '%s' "$config" | jq -e '.dns.servers[0].path=="/p0"' >/dev/null || fail 'runtime catalog HTTP path'
for protocol in doq h3; do
  if sing_box_cf_add_dns_server '{"dns":{"servers":[]}}' "$protocol" main dns.quad9.net '' '' >"$work/out" 2>"$work/error"; then fail 'unsupported engine protocol generated'; fi
  grep -q 'unsupported_engine_protocol' "$work/error" || fail 'unsupported protocol became generic error'
done
if sing_box_cf_add_dns_server '{"dns":{"servers":[]}}' doh bootstrap dns.example '' '' >/dev/null 2>&1; then fail 'encrypted bootstrap hostname fell back to system resolver'; fi
uci() { case "$*" in *bootstrap_dns_type*) echo udp;; *bootstrap_dns_server*) echo 8.8.8.8;; *dns_type*) echo dot;; *dns_server*) echo cloudflare-dns.com;; *) return 1;; esac; }
resolve_host() { [ "$2" = one.one.one.one ] || return 1; echo 192.0.2.8; }
run_dns_query() { [ "$1|$2|$3|$4" = 'dot|192.0.2.8|one.one.one.one|/dns-query' ] || return 1; echo 1; }
probe="$(probe_configured_pair primary)" || fail 'health probe ignored catalog TLS host'
printf '%s' "$probe" | jq -e '.success' >/dev/null || fail 'catalog TLS health probe failed'
uci() { case "$*" in *bootstrap_dns_type*) echo udp;; *bootstrap_dns_server*) echo 8.8.8.8;; *dns_type*) echo doq;; *dns_server*) echo dns.quad9.net;; *) return 1;; esac; }
if probe="$(probe_configured_pair primary)"; then fail 'unsupported engine protocol reported healthy'; fi
printf '%s' "$probe" | jq -e '.success==false and .error=="unsupported_engine_protocol"' >/dev/null || fail 'unsupported health protocol lost structured engine error'
sed -n '/^check_dns_available() {/,/^}/p' "$repo/openwrt/runtime-0.7.23/usr/bin/podkop" > "$work/diagnostic"
. "$work/diagnostic"
# Instrument process/config boundaries; exercise the real diagnostic function.
printf '%s\n' '#!/bin/sh' '[ "$1|$2" = "probe_pair|primary" ] || exit 1' 'printf "{\"success\":true}"' > "$work/pair-probe"
chmod +x "$work/pair-probe"
export PODKOP_DNS_BENCHMARK_COMMAND="$work/pair-probe"
config_get() {
  local value
  case "$3" in dns_type) value=dot;; dns_server) value=cloudflare-dns.com;; bootstrap_dns_server) value=8.8.8.8;; bootstrap_dns_type) value=udp;; *) value="${4:-}";; esac
  eval "$1=\$value"
}
config_load() { :; }
config_foreach() { :; }
dig() { [ "$1" = @127.0.0.1 ]; }
PODKOP_CONFIG=podkop
diagnostic="$(check_dns_available)"
printf '%s' "$diagnostic" | jq -e '.dns_status==1 and .bootstrap_dns_status==1' >/dev/null || fail 'encrypted diagnostic bypassed catalog-aware pair probe'
(
  # Restore the real query implementation and intercept only its dig boundary.
  . "$repo/openwrt/podkop-dns-optimizer"
  run_with_timeout() { shift; "$@"; }
  dig() {
    case " $* " in *" -p $QUERY_EXPECTED_PORT "*) ;; *) return 1;; esac
    case "$QUERY_PROTOCOL" in
      doh) case " $* " in *' +https=/dns-custom '*) ;; *) return 1;; esac;;
      dot) case " $* " in *' +tls '*) ;; *) return 1;; esac;;
    esac
    case "$QUERY_PROTOCOL" in
      doh|dot) case " $* " in *' +tls-hostname=dns.custom.example '*) ;; *) return 1;; esac;;
    esac
    printf '%s\n' ';; status: NOERROR' 'example.com. 60 IN A 8.8.4.4' ';; Query time: 1 msec'
  }
  for QUERY_PROTOCOL in udp tcp doh dot; do
    case "$QUERY_PROTOCOL" in doh) QUERY_EXPECTED_PORT=8443;; dot) QUERY_EXPECTED_PORT=8853;; *) QUERY_EXPECTED_PORT=5353;; esac
    [ "$(run_dns_query "$QUERY_PROTOCOL" 1.1.1.1 dns.custom.example /dns-custom example.com NOERROR "$QUERY_EXPECTED_PORT")" = 1 ] || fail "$QUERY_PROTOCOL query discarded explicit endpoint port"
  done
  uci() {
    case "$*" in
      *bootstrap_dns_type*) echo udp;; *bootstrap_dns_server*) echo 8.8.8.8;;
      *dns_type*) echo "$QUERY_PROTOCOL";; *dns_server*) echo "$QUERY_SERVER";; *) return 1;;
    esac
  }
  resolve_host() { [ "$2" = dns.custom.example ] || return 1; echo 1.1.1.1; }
  for QUERY_PROTOCOL in doh dot; do
    case "$QUERY_PROTOCOL" in doh) QUERY_EXPECTED_PORT=8443; QUERY_SERVER=dns.custom.example:8443/dns-custom;; dot) QUERY_EXPECTED_PORT=8853; QUERY_SERVER=dns.custom.example:8853;; esac
    probe="$(probe_configured_pair primary)" || fail "$QUERY_PROTOCOL health probe discarded configured port"
    printf '%s' "$probe" | jq -e '.success' >/dev/null || fail 'nondefault-port health probe failed'
  done
)
echo 'PASS: supported DNS transports, catalog endpoint metadata and noncircular encrypted bootstrap'
