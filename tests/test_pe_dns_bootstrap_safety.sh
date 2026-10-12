#!/bin/bash
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1 PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
. "$repo/openwrt/podkop-dns-optimizer"
fail() { echo "FAIL: $*" >&2; exit 1; }
# Mock only DNS packets/timeouts; keep actual endpoint lookup, parser and pair orchestration.
run_with_timeout() { shift; "$@"; }
dig() {
    printf '%s\n' "$*" >> "$work/dig.calls"
    local resolver="${1#@}" domain='' arg
    for arg in "$@"; do
        case "$arg" in example.com|github.com|dns.quad9.net|podkop-bootstrap-test.invalid) domain="$arg";; esac
    done
    [ "$resolver" != "${dead_server:-none}" ] || { echo ';; connection timed out'; return 1; }
    if [ "$domain" = podkop-bootstrap-test.invalid ]; then
        [ "${bad_nxdomain:-0}" = 0 ] && echo ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1' || echo ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1'
    elif [ "$domain" = "${bad_domain:-none}" ]; then
        echo ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1'
    else
        echo ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1'
        printf '%s 60 IN A 93.184.216.34\n' "${domain:-fixture.example}"
    fi
    echo ';; Query time: 7 msec'
}
for protocol in udp tcp doh dot; do
    probe_bootstrap "$protocol" 8.8.8.8 dns.quad9.net > "$work/result" || fail "$protocol bootstrap unavailable"
    jq -e --arg protocol "$protocol" '.success==true and .protocol==$protocol and .server=="8.8.8.8" and (.checks|length)==4 and (.checks|all(.success==true))' "$work/result" >/dev/null || fail 'bootstrap result contract'
done
grep -q '+tcp' "$work/dig.calls" || fail 'TCP not used'
grep -q '+https=/dns-query +tls-hostname=dns.google' "$work/dig.calls" || fail 'DoH TLS endpoint not preserved'
grep -q '+tls +tls-hostname=dns.google' "$work/dig.calls" || fail 'DoT TLS endpoint not preserved'
bad_domain=dns.quad9.net
! probe_bootstrap udp 8.8.8.8 dns.quad9.net > "$work/result" || fail 'unresolvable main hostname accepted'
jq -e '.success==false and (.checks|any(.domain=="dns.quad9.net" and .success==false and .reason!=""))' "$work/result" >/dev/null || fail 'missing concrete failure domain/reason'
bad_domain=none; bad_nxdomain=1
! probe_bootstrap udp 8.8.8.8 > "$work/result" || fail 'NXDOMAIN hijacking accepted'
bad_nxdomain=0
for protocol in doq h3; do
    ! probe_bootstrap "$protocol" 8.8.8.8 > "$work/result" || fail 'unsupported bootstrap transport accepted'
    jq -e '.success==false and .error=="unsupported_engine_protocol"' "$work/result" >/dev/null
done
uci() {
    case "$*" in
        *bootstrap_dns_type) echo "${boot_type:-udp}";;
        *bootstrap_dns_server) echo 8.8.8.8;;
        *dns_type) echo udp;;
        *dns_server) echo 1.1.1.1;;
        *) return 1;;
    esac
}
dead_server=8.8.8.8
! probe_configured_pair primary > "$work/result" || fail 'numeric primary skipped dead bootstrap'
jq -e '.success==false and .error=="bootstrap_failed" and .bootstrap.success==false' "$work/result" >/dev/null || fail 'pair lacks bootstrap failure evidence'
for boot_type in tcp doh dot; do
    ! probe_configured_pair primary > "$work/result" || fail 'encrypted bootstrap failure delegated away'
    jq -e '.error=="bootstrap_failed"' "$work/result" >/dev/null
done
echo 'PASS: independent bootstrap all supported transports, concrete checks, NXDOMAIN, numeric primary and fail-closed delegation'
