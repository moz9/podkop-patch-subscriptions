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
    'saved_custom_udp_1|Saved custom DNS 1|77.88.8.88' \
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
  {"id":"cloudflare","provider":"Cloudflare","dnsServer":"1.1.1.1","primaryEligible":true,"score":100},
  {"id":"google","provider":"Google","dnsServer":"8.8.8.8","primaryEligible":true,"score":90}
]'
primary_id="$(printf '%s\n' "$ranking_fixture" | jq -r 'map(select(.primaryEligible == true)) | sort_by(.score) | reverse | .[0].id // ""')"
secondary_id="$(printf '%s\n' "$ranking_fixture" | jq -r --arg primary "$primary_id" 'map(select(.primaryEligible == true and .id != $primary)) | sort_by(.score) | reverse | .[0].id // ""')"
only_yandex="$(printf '%s\n' '[{"id":"yandex","primaryEligible":false}]' | jq -r 'map(select(.primaryEligible == true)) | .[0].id // ""')"
if [ "$primary_id" != cloudflare ] || [ "$secondary_id" != google ] || [ -n "$only_yandex" ]; then
    fail 'fixture policy must exclude Yandex from both primary and secondary ranking'
fi

uci() {
    case "$*" in
        *podkop.settings.dns_optimizer_candidates) printf '%s\n' 'cloudflare google yandex' ;;
        *podkop.settings.dns_optimizer_custom_udp) printf '%s\n' '77.88.8.8 1.1.1.1' ;;
        *podkop.settings.dns_optimizer_include_current) printf '%s\n' 1 ;;
        *podkop.settings.dns_type) printf '%s\n' udp ;;
        *podkop.settings.dns_server) printf '%s\n' 77.88.8.1 ;;
        *podkop.settings.bootstrap_dns_server) printf '%s\n' 1.1.1.1 ;;
        *podkop.settings.dns_failover_enabled) printf '%s\n' 0 ;;
        *podkop.settings.dns_failover_active_slot) printf '%s\n' primary ;;
        *podkop.settings.dns_optimizer_include_wan) printf '%s\n' 0 ;;
        *) return 1 ;;
    esac
}
configured_active_slot() { printf '%s\n' primary; }
read_configured_pair() { printf '%s\n' 'udp|77.88.8.1|1.1.1.1'; }

main_candidates="$test_root/main-candidates"
write_main_candidates udp "$main_candidates"
if grep -Eiq '(^|\|)(yandex|77\.88\.8\.(8|1)|common\.dot\.dns\.yandex\.net)(\||$)' "$main_candidates"; then
    fail 'legacy selector, custom, or current settings leaked Yandex into normal DNS candidates'
fi
if ! grep -q '^cloudflare|' "$main_candidates"; then
    fail 'normal non-Yandex candidates were unexpectedly removed'
fi

bootstrap_candidates="$test_root/bootstrap-candidates"
write_bootstrap_candidates "$bootstrap_candidates"
if ! grep -q '^yandex_1|Yandex|77\.88\.8\.8|' "$bootstrap_candidates"; then
    fail 'Yandex must remain available in the bootstrap DNS catalog'
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

if ! grep -q 'secondary_recommendation="$(printf.*"\$primary_ranking"' openwrt/podkop-dns-optimizer; then
    fail 'secondary selection must use the Yandex-free normal DNS ranking'
fi

if ! sed -n '/^run_apply() {/,/^}/p' openwrt/podkop-dns-optimizer |
    grep -q 'candidate_is_primary_eligible'; then
    fail 'backend apply must reject Yandex in the secondary DNS slot'
fi

if ! grep -q 'primaryEligible: false' openwrt/settings.js; then
    fail 'UI fallback policy must also mark Yandex ineligible for primary DNS'
fi

if ! grep -q 'candidate.primaryEligible !== false' openwrt/settings.js; then
    fail 'UI normal DNS recommendation must enforce eligibility'
fi

if sed -n '/^const NORMAL_DNS_OPTIMIZER_CANDIDATES = \[/,/^\];/p; /^const DEFAULT_NORMAL_DNS_OPTIMIZER_CANDIDATES = \[/,/^\];/p' openwrt/settings.js |
    grep -Eqi '"yandex'; then
    fail 'normal DNS selector/default must not offer Yandex'
fi

if ! sed -n '/^function pickSecondaryFor(status, primary) {/,/^}/p' openwrt/settings.js |
    grep -q 'candidateIsPrimaryEligible(candidate)'; then
    fail 'UI secondary recommendation must reject Yandex, including legacy benchmark data'
fi

if ! sed -n '/^async function applyDnsResult(result, secondaryResult = null) {/,/^}/p' openwrt/settings.js |
    grep -q 'candidateIsPrimaryEligible(secondaryResult)'; then
    fail 'UI apply must reject Yandex in the secondary DNS slot'
fi

if ! sed -n '/^function renderMainResults(status, running) {/,/^}/p' openwrt/settings.js |
    grep -q 'filter(candidateIsPrimaryEligible)'; then
    fail 'legacy Yandex benchmark rows must be hidden from normal DNS results'
fi

if ! sed -n '/^function dnsEndpointHost(value) {/,/^}/p' openwrt/settings.js |
    grep -Fq '.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")'; then
    fail 'UI legacy fallback must normalize DoH and DoT URL schemes before Yandex detection'
fi

if ! sed -n '/^function candidateIsPrimaryEligible(candidate) {/,/^}/p' openwrt/settings.js |
    grep -q 'provider.startsWith("yandex ")'; then
    fail 'UI legacy fallback must recognize Yandex by provider as well as endpoint'
fi

printf '%s\n' 'PASS: Yandex is available only as bootstrap DNS'
