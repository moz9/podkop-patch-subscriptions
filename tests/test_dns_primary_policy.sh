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
policy_functions="$test_root/policy-functions.sh"
awk '/^query_status\(\) \{/ { exit } { sub(/\r$/, ""); print }' \
    openwrt/podkop-dns-optimizer > "$policy_functions"
. "$policy_functions"

for candidate in \
    'yandex|Yandex Basic|77.88.8.8' \
    'yandex|Yandex Basic|common.dot.dns.yandex.net' \
    'current|Current DNS|77.88.8.1'; do
    old_ifs="$IFS"
    IFS='|'
    set -- $candidate
    IFS="$old_ifs"
    if candidate_is_primary_eligible "$1" "$2" "$3"; then
        fail "Yandex candidate was accepted for primary DNS: $candidate"
    fi
done

if ! candidate_is_primary_eligible cloudflare Cloudflare 1.1.1.1; then
    fail 'non-Yandex safe candidate was rejected for primary DNS'
fi

ranking_fixture='[
  {"id":"yandex","provider":"Yandex Basic","dnsServer":"77.88.8.8","primaryEligible":false,"score":200},
  {"id":"cloudflare","provider":"Cloudflare","dnsServer":"1.1.1.1","primaryEligible":true,"score":100}
]'
primary_id="$(printf '%s\n' "$ranking_fixture" | jq -r 'map(select(.primaryEligible == true)) | sort_by(.score) | reverse | .[0].id // ""')"
secondary_id="$(printf '%s\n' "$ranking_fixture" | jq -r --arg primary "$primary_id" 'map(select(.id != $primary)) | sort_by(.score) | reverse | .[0].id // ""')"
only_yandex="$(printf '%s\n' '[{"id":"yandex","primaryEligible":false}]' | jq -r 'map(select(.primaryEligible == true)) | .[0].id // ""')"
if [ "$primary_id" != cloudflare ] || [ "$secondary_id" != yandex ] || [ -n "$only_yandex" ]; then
    fail 'fixture policy must choose Cloudflare primary, allow Yandex secondary, and reject Yandex-only primary'
fi

if ! grep -q 'primaryEligible' openwrt/podkop-dns-optimizer; then
    fail 'DNS optimizer must expose an explicit primary eligibility policy'
fi

if ! grep -q -- '--argjson primaryEligible false' openwrt/podkop-dns-optimizer; then
    fail 'Yandex candidates must be marked ineligible for primary DNS'
fi

if ! grep -q 'select(.primaryEligible == true)' openwrt/podkop-dns-optimizer; then
    fail 'primary DNS ranking must filter by primary eligibility'
fi

if ! grep -q 'secondary_recommendation="$(printf.*"\$safe_ranking"' openwrt/podkop-dns-optimizer; then
    fail 'secondary selection must keep the full safe ranking, including Yandex'
fi

if ! grep -q 'primaryEligible: false' openwrt/settings.js; then
    fail 'UI fallback policy must also mark Yandex ineligible for primary DNS'
fi

if ! grep -q 'candidate.primaryEligible !== false' openwrt/settings.js; then
    fail 'UI primary recommendation must enforce primary eligibility'
fi

if ! sed -n '/^function dnsEndpointHost(value) {/,/^}/p' openwrt/settings.js |
    grep -Fq '.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")'; then
    fail 'UI legacy fallback must normalize DoH and DoT URL schemes before Yandex detection'
fi

if ! sed -n '/^function candidateIsPrimaryEligible(candidate) {/,/^}/p' openwrt/settings.js |
    grep -q 'provider.startsWith("yandex ")'; then
    fail 'UI legacy fallback must recognize Yandex by provider as well as endpoint'
fi

printf '%s\n' 'PASS: Yandex is excluded only from automatic primary DNS selection'
