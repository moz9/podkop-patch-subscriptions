#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
awk '/^dns_diagnostic_query\(\)|^check_dns_available\(\)/{inside=1} inside{print} inside && /^}$/{inside=0}' "$repo/openwrt/runtime-0.7.24/usr/bin/podkop" > "$work/functions"
. "$work/functions"
PODKOP_CONFIG=podkop
PODKOP_DNS_BENCHMARK_COMMAND=/bin/false
fixture_dns_type=doh
fixture_dns_server=cloudflare-dns.com
fixture_failure=''
config_get() {
    case "$3" in
      dns_type) eval "$1=\$fixture_dns_type";;
      dns_server) eval "$1=\$fixture_dns_server";;
      bootstrap_dns_type) eval "$1=udp";;
      bootstrap_dns_server) eval "$1=77.88.8.8";;
      *) eval "$1=''";;
    esac
}
config_load() { :; }
config_foreach() { :; }
dig() {
    printf '%s\n' "$*" >> "$work/dig-calls"
    case "$fixture_failure:$1" in
      hang:*) exec sleep 30;;
      empty:*) return 0;;
      servfail:*) printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'; return 0;;
      primary:@cloudflare-dns.com) return 1;;
    esac
    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
    printf 'google.com. 60 IN A 142.250.0.1\n'
}
result="$(check_dns_available)"
printf '%s' "$result" | jq -e '.dns_status==1 and .bootstrap_dns_status==1 and .dns_on_router==1' >/dev/null || fail 'ordinary DoH diagnostic still requires benchmark instead of bounded direct DNS probes'
grep -q '+https=/dns-query' "$work/dig-calls" || fail 'DoH primary was not queried directly'
grep -q '@127.0.0.1' "$work/dig-calls" || fail 'running local DNS was not checked'
for fixture_failure in empty servfail primary; do
    result="$(check_dns_available)"
    printf '%s' "$result" | jq -e '.dns_status==0' >/dev/null || fail "$fixture_failure falsely reported primary healthy"
done
fixture_failure=''; fixture_dns_type=dot; fixture_dns_server=one.one.one.one
check_dns_available >/dev/null
grep -q '+tls' "$work/dig-calls" || fail 'DoT primary was not queried directly'
fixture_failure=hang
start="$(date +%s)"
! dns_diagnostic_query 127.0.0.1 udp google.com >/dev/null || fail 'hung query was accepted'
elapsed=$(( $(date +%s)-start ))
[ "$elapsed" -le 4 ] || fail 'native DNS probe exceeded bounded deadline'
fixture_failure=hang
start="$(date +%s)"
result="$(check_dns_available)"
elapsed=$(( $(date +%s)-start ))
[ "$elapsed" -le 11 ] || fail 'overall ordinary diagnostic exceeds the 15-second UI deadline'
printf '%s' "$result" | jq -e '.dns_status==0 and .bootstrap_dns_status==0 and .dns_on_router==0' >/dev/null || fail 'hung DNS probes falsely reported health'
# Incremental installations must replace just the diagnostics, not the core or
# subscription state. The same patch is idempotent and requires one old method.
sed '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo/i" > "$work/installer-library"
. "$work/installer-library"
command -v install_bounded_dns_diagnostics >/dev/null || fail 'installer does not deliver bounded DNS diagnostics'
printf 'before() { :; }\ncheck_dns_available() {\n echo old\n}\nafter() { :; }\n' > "$work/target"
install_bounded_dns_diagnostics "$repo/openwrt/runtime-0.7.24/usr/bin/podkop" "$work/target" || fail 'targeted diagnostic upgrade failed'
grep -q '^before()' "$work/target" && grep -q '^after()' "$work/target" || fail 'diagnostic upgrade changed unrelated core functions'
[ "$(grep -c '^dns_diagnostic_query()' "$work/target")" = 1 ] || fail 'diagnostic helper missing/duplicated'
first="$(sha256sum "$work/target")"
install_bounded_dns_diagnostics "$repo/openwrt/runtime-0.7.24/usr/bin/podkop" "$work/target" || fail 'idempotent diagnostic upgrade failed'
[ "$first" = "$(sha256sum "$work/target")" ] || fail 'repeat upgrade changed bytes'
printf 'no_diagnostic() { :; }\n' > "$work/invalid"
invalid_before="$(sha256sum "$work/invalid")"
! install_bounded_dns_diagnostics "$repo/openwrt/runtime-0.7.24/usr/bin/podkop" "$work/invalid" || fail 'unsupported target accepted'
[ "$invalid_before" = "$(sha256sum "$work/invalid")" ] || fail 'unsupported target was modified'
cmp -s "$repo/i" "$repo/openwrt/install.sh" || fail 'installer delivery copies diverged'
printf 'PASS: ordinary DNS diagnostics avoid benchmark, independently verify primary/bootstrap/local DNS, reject empty/SERVFAIL and bound native queries\n'
