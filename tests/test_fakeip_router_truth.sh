#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM
runtime="openwrt/runtime-0.7.20/usr/bin/podkop"
runtime_functions="$test_root/runtime-functions.sh"
dig_log="$test_root/dig.log"
curl_log="$test_root/curl.log"

extract_check_fakeip() {
    awk '
        /^check_fakeip\(\) \{$/ { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$1"
}

extract_check_fakeip "$runtime" > "$runtime_functions"
. "$runtime_functions"

curl() {
    printf '%s\n' "$*" >> "$curl_log"
    return 28
}

dig() {
    printf '%s\n' "$*" >> "$dig_log"
    [ -z "${FAKEIP_TEST_DIG_OUTPUT:-}" ] || printf '%s\n' "$FAKEIP_TEST_DIG_OUTPUT"
}

assert_check() {
    description="$1"
    dig_output="$2"
    expected_fakeip="$3"
    expected_dns_available="$4"

    : > "$dig_log"
    : > "$curl_log"
    FAKEIP_TEST_DIG_OUTPUT="$dig_output"
    export FAKEIP_TEST_DIG_OUTPUT

    set +e
    output="$(check_fakeip)"
    status=$?
    set -e

    [ "$status" -eq 0 ] || fail "$description returned status $status"
    printf '%s\n' "$output" | jq -e . > /dev/null 2>&1 ||
        fail "$description did not return structured JSON"
    actual_fakeip="$(printf '%s\n' "$output" | jq -r '.fakeip')"
    actual_ip="$(printf '%s\n' "$output" | jq -r '.IP')"
    actual_dns_available="$(printf '%s\n' "$output" | jq -r '.dnsAvailable')"
    [ "$actual_fakeip" = "$expected_fakeip" ] ||
        fail "$description returned fakeip=$actual_fakeip instead of $expected_fakeip"
    [ "$actual_dns_available" = "$expected_dns_available" ] ||
        fail "$description returned dnsAvailable=$actual_dns_available instead of $expected_dns_available"
    [ -z "$actual_ip" ] ||
        fail "$description returned a compatibility IP value despite using a local-only check"
    if [ -s "$curl_log" ]; then
        fail "$description called an external HTTP service"
    fi
    grep -q '^+short @127\.0\.0\.1 fakeip\.podkop\.fyi$' "$dig_log" ||
        fail "$description did not query router DNS directly at 127.0.0.1"
    if grep -q '@127\.0\.0\.42' "$dig_log"; then
        fail "$description queried sing-box DNS directly instead of router DNS"
    fi
}

assert_check \
    'upper-half FakeIP answer' \
    '198.19.255.254' true true

assert_check \
    'public router DNS answer' \
    '203.0.113.53' false true

assert_check \
    'lower-half FakeIP answer' \
    '198.18.0.7' true true

assert_check \
    'no router DNS answer' \
    '' false false

legacy_runtime="$test_root/legacy-podkop"
legacy_helpers="$test_root/missing-helpers.sh"
sed '/fakeip_router_dns_truth_v4=1/d' "$runtime" > "$legacy_runtime"
PODKOP_MAINTENANCE_TARGET="$legacy_runtime" \
PODKOP_MAINTENANCE_HELPERS_TARGET="$legacy_helpers" \
    sh openwrt/podkop-subscription-maintenance-upgrade.sh

grep -q 'fakeip_router_dns_truth_v4=1' "$legacy_runtime" ||
    fail 'maintenance upgrade did not migrate an existing v3 check_fakeip implementation'
extract_check_fakeip "$runtime" > "$test_root/canonical-check-fakeip.sh"
extract_check_fakeip "$legacy_runtime" > "$test_root/upgraded-check-fakeip.sh"
cmp -s "$test_root/canonical-check-fakeip.sh" "$test_root/upgraded-check-fakeip.sh" ||
    fail 'maintenance upgrade check_fakeip differs from the canonical runtime'

marker='fakeip_router_dns_truth_v4'
for installer in i openwrt/install.sh; do
    grep -q "$marker" "$installer" ||
        fail "$installer does not require the current FakeIP runtime marker"
done

printf '%s\n' 'PASS: router FakeIP truth is local, complete, and structured'
