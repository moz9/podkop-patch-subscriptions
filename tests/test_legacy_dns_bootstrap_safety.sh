#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Legacy optimizer has no Engine/catalog/library dependency.
eval "$(sed '/^case "${1:-}" in/,$d' "$repo/openwrt/podkop-dns-optimizer")"
fail() { echo "FAIL: $*" >&2; exit 1; }
run_with_timeout() { shift; "$@"; }
dig() {
    echo "$*" >> "$work/dig.calls"
    local resolver="${1#@}" domain='' arg short=0
    for arg in "$@"; do
        case "$arg" in example.com|github.com|dns.example|podkop-bootstrap-test.invalid) domain="$arg";; +short) short=1;; esac
    done
    [ "$resolver" != "${dead_server:-none}" ] || { echo ';; connection timed out'; return 1; }
    if [ "$short" = 1 ]; then echo 93.184.216.34; return 0; fi
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
probe_bootstrap udp 8.8.8.8 dns.example > "$work/result" || fail 'independent UDP bootstrap unavailable'
jq -e '.success==true and .protocol=="udp" and .server=="8.8.8.8" and (.checks|length)==4 and (.checks|all(.success==true))' "$work/result" >/dev/null || fail 'bootstrap contract'
bad_domain=dns.example
! probe_bootstrap udp 8.8.8.8 dns.example > "$work/result" || fail 'main hostname failure accepted'
jq -e '.success==false and (.checks|any(.domain=="dns.example" and .success==false and .reason=="unexpected_status:SERVFAIL"))' "$work/result" >/dev/null || fail 'main hostname failure lacks concrete reason'
bad_domain=none; bad_nxdomain=1
! probe_bootstrap udp 8.8.8.8 > "$work/result" || fail 'NXDOMAIN hijack accepted'
bad_nxdomain=0
for protocol in doq h3; do
    ! probe_bootstrap "$protocol" 8.8.8.8 > "$work/result" || fail 'unsupported stable bootstrap protocol accepted'
    jq -e '.success==false and .error=="unsupported_engine_protocol"' "$work/result" >/dev/null
done
uci() {
    case "$*" in
        *bootstrap_dns_type) echo "${boot_type:-udp}";;
        *bootstrap_dns_server) echo 8.8.8.8;;
        *dns_type) echo "${main_type:-udp}";;
        *dns_server) if [ "${main_type:-udp}" = udp ]; then echo 1.1.1.1; else echo dns.example/dns-query; fi;;
        *) return 1;;
    esac
}
dead_server=8.8.8.8
! probe_configured_pair primary > "$work/result" || fail 'numeric primary skipped dead bootstrap'
jq -e '.success==false and .error=="bootstrap_failed" and .bootstrap.success==false' "$work/result" >/dev/null || fail 'configured pair lacks independent failure evidence'
dead_server=none
for main_type in udp doh dot; do
    probe_configured_pair primary > "$work/result" || fail 'legacy main protocol regressed'
    jq -e '.success==true' "$work/result" >/dev/null
done
boot_type=doh
! probe_configured_pair secondary > "$work/result" || fail 'missing native pair helper accepted'
jq -e '.error=="pair_probe_failed" and .bootstrap.success==true' "$work/result" >/dev/null
grep -q '+https=/dns-query +tls-hostname=dns.example' "$work/dig.calls" || fail 'legacy main DoH hostname lost'
grep -q '+tls +tls-hostname=dns.example' "$work/dig.calls" || fail 'legacy main DoT hostname lost'
echo 'PASS: independent bootstrap, numeric-primary failure, native encrypted-helper admission, legacy main protocols preserved'
