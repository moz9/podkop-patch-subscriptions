#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir -p "$db_work"
db_fingerprint() { echo stable; }; db_busy() { return 1; }; db_runtime_safe() { return 0; }
db_validate_pair() { :; }; db_parallel_limit() { echo 2; }
configured_active_slot() { echo primary; }
read_configured_pair() { echo 'udp|1.1.1.1|8.8.8.8'; }
uci() { case "$*" in *dns_optimizer_protocols) echo 'udp tcp';; *dns_optimizer_bootstrap_protocols) echo udp;; set*|commit*|delete*) fail 'UCI mutation';; *) return 1;; esac; }
write_main_candidates() {
    case "$1" in udp) printf '%s\n' 'first|First|1.1.1.1|unfiltered' 'second|Second|8.8.8.8|unfiltered' 'third|Third|9.9.9.10|unfiltered';;
      tcp) printf '%s\n' 'fourth|Fourth|1.1.1.1|unfiltered' 'fifth|Fifth|8.8.8.8|unfiltered';; esac > "$2"
}
write_bootstrap_candidates() { printf '%s\n' 'b1|First|1.1.1.1|unfiltered' 'b2|Second|8.8.8.8|unfiltered' 'b3|Third|9.9.9.10|unfiltered' 'b4|Fourth|1.0.0.1|unfiltered' > "$1"; }
# Only the external DNS listener/measurement is stubbed; production catalog,
# shortlist, queue, confirmations, status publication and isolation are real.
db_native_start() { probe_fixture_server="$2"; printf '%s|%s|%s\n' "${5:-}" "$1" "$2" >> "$work/endpoints"; }
db_child_stop() { :; }
db_query() {
    case "$1" in *.invalid) echo NXDOMAIN;; *)
        if [ "${quick_failure_fixture:-false}" = true ] && [ "$probe_fixture_server" = 9.9.9.10 ]; then echo 'ERROR|TIMEOUT'; return 1; fi
        echo 'NOERROR|10';; esac
}
db_check_pair() {
    [ "$(wc -l < "$work/endpoints")" = 9 ] || fail 'pair started before complete independent endpoint coverage'
    printf '%s|%s|%s\n' "$db_phase" "$2" "$4" >> "$work/pairs"
    score=20; success=true
    if [ "$3:$4" = '1.1.1.1:8.8.8.8' ]; then score=0; fi
    if [ "${unstable_fixture:-false}" = true ] && [ "$db_phase" = recheck ] && [ "$db_pairs_tested" -lt 16 ]; then success=false; fi
    if [ "${failed_fixture:-false}" = true ] && [ "$db_pairs_tested" -lt 8 ]; then success=false; fi
    db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" "$success" "$5" | jq --argjson score "$score" --argjson success "$success" '.httpsTested=true|.stats={reliable:$success,averageMs:$score,scoreMs:$score}|.sectionResults=[]')"
    if [ "${cancel_fixture:-false}" = true ]; then : > "$work/state/cancel"; fi
}
run() {
    : > "$work/endpoints"; : > "$work/pairs"
    db_action=recommend; db_deadline=$(( $(date +%s)+300 ))
    db_recommend
}
run || fail 'staged recommendation failed'
db_status | jq -e '.selectionMode=="two_stage" and .recommendationMode=="two_stage" and .stage=="complete" and .endpointCoverage.main=={selected:5,tested:5} and .endpointCoverage.bootstrap=={selected:4,tested:4}' >/dev/null || fail 'two-stage mode or complete endpoint coverage absent'
db_status | jq -e '.shortlistLimit==8 and .shortlistedPairs==8 and .pairsTested==8 and .httpsTestedPairs==8 and .untestedHttpsPairs==12 and .candidatesTotal==20 and .exhaustiveSelected==false and .confirmationChecks>=2 and .stableEligiblePairs>=2 and .searchComplete==false' >/dev/null || fail 'staged coverage/bounded shortlist/repeats missing'
db_status | jq -e '(.pairResults|length)==8 and (.pairResults|any(.currentPair==true and .comparisonOnly==true and .automaticEligible==false)) and .recommendation.currentPair!=true and (.pairResults|map(.protocol)|unique|length)==2 and (.pairResults|map(.id)|unique|length)>=4 and (.pairResults|map(.bootstrapDnsServer)|unique|length)==4' >/dev/null || { db_status | jq '[.pairResults[]|{id,protocol,bootstrapDnsServer,currentPair,automaticEligible}]' >&2; fail 'current comparison/provider/protocol diversity lost'; }
db_status | jq -e '.individualComplete and (.results|all(.measured and .precheckOnly and .reliable==false and .httpsTested==false)) and (.bootstrapResults|all(.measured and .precheckOnly))' >/dev/null || fail 'cheap DNS prechecks claimed compatibility'
[ ! -s "$DB_PROOF" ] || fail 'recommendation granted proof'
(
    read_configured_pair() { echo 'doh|1.1.1.1|77.88.8.1'; }
    run || fail 'outside-selected current pair failed'
    db_status | jq -e '.candidatesTotal==21 and .endpointCoverage.main.selected==5 and .endpointCoverage.bootstrap.selected==4 and (.pairResults|any(.currentPair and .protocol=="doh" and .bootstrapDnsServer=="77.88.8.1" and .automaticEligible==false))' >/dev/null || fail 'outside-selected current pair missing or polluted selected coverage'
)
(
    read_configured_pair() { echo 'doh|1.1.1.1|8.8.8.8'; }
    write_main_candidates() {
        case "$1" in udp) printf '%s\n' 'first|First|1.1.1.1|unfiltered' 'second|Second|8.8.8.8|unfiltered' 'third|Third|9.9.9.10|unfiltered';;
          tcp) printf '%s\n' 'fourth|Fourth|1.1.1.1|unfiltered' 'fifth|Fifth|8.8.8.8|unfiltered';;
          doh) printf '%s\n' 'cloudflare|Cloudflare|cloudflare-dns.com|unfiltered';; esac > "$2"
    }
    uci() { case "$*" in *dns_optimizer_protocols) echo 'udp tcp doh';; *dns_optimizer_bootstrap_protocols) echo udp;; *) return 1;; esac; }
    db_check_pair() { db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" true "$5" | jq '.httpsTested=true|.stats={reliable:true,averageMs:20,scoreMs:20}|.sectionResults=[]')"; }
    run || fail 'canonical current pair alias failed'
    db_status | jq -e '.candidatesTotal==24 and ([.pairResults[]|select(.currentPair)]|length)==1 and (.pairResults|any(.currentPair and .id=="cloudflare" and .dnsServer=="cloudflare-dns.com"))' >/dev/null || fail 'configured IP alias duplicated canonical current row'
)
failed_fixture=true
run || fail 'failed first shortlist did not expand'
db_status | jq -e '.pairsTested==16 and .untestedHttpsPairs==4 and .stableEligiblePairs>=2' >/dev/null || fail 'working-pair expansion missing'
failed_fixture=false; unstable_fixture=true
run || fail 'unstable first shortlist did not expand'
db_status | jq -e '.pairsTested==16 and .stableEligiblePairs>=2 and .recommendation!=null' >/dev/null || fail 'repeat instability did not expand finalists'
unstable_fixture=false; quick_failure_fixture=true
run || fail 'failed direct DNS prechecks blocked staged recommendation'
db_status | jq -e '(.results|any(.id=="third" and .measured and .quickReliable==false)) and (.pairResults|all(.id!="third" and .bootstrapDnsServer!="9.9.9.10"))' >/dev/null || fail 'failed quick probes outranked viable diverse endpoints'
failed_fixture=true
run || fail 'failed direct DNS precheck excluded expansion candidates'
db_status | jq -e '.pairsTested==16 and (.pairResults|any(.id=="third" and .automaticEligible and .success))' >/dev/null || fail 'direct precheck failure excluded proxy-route finalist'
failed_fixture=false; quick_failure_fixture=false
unstable_fixture=false; cancel_fixture=true
if run; then fail 'cancelled staged selection succeeded'; fi
db_status | jq -e '.recommendation==null and .selectionComplete==false and .error=="cancelled"' >/dev/null || fail 'cancelled staged selection published a winner'
echo 'PASS: staged endpoint coverage, diverse shortlist, current comparison, expansion and cancellation'
