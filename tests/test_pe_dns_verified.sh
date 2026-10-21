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
db_fingerprint() { if [ -f "$work/changed" ]; then echo changed; else echo stable; fi; }
db_busy() { return 1; }; db_runtime_safe() { return 0; }; db_validate_pair() { return 0; }; db_parallel_limit() { echo 2; }
configured_active_slot() { echo primary; }; read_configured_pair() { echo 'udp|1.1.1.1|8.8.8.8'; }
uci() { case "$*" in *dns_optimizer_protocols|*dns_optimizer_bootstrap_protocols) echo udp;; set*|commit*|delete*) fail 'verified mode wrote UCI';; *) return 1;; esac; }
write_main_candidates() { printf '%s\n' 'first|First|1.1.1.1|unfiltered' 'second|Second|8.8.8.8|unfiltered' 'third|Third|9.9.9.10|unfiltered' > "$2"; }
write_bootstrap_candidates() { printf '%s\n' 'b1|First|1.1.1.1|unfiltered' 'b2|Second|8.8.8.8|unfiltered' > "$1"; }
db_child_start() { echo endpoint >> "$work/endpoints"; }; db_child_stop() { :; }
db_query() { case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|10';; esac; }
db_check_pair() {
    score=3; case "$2" in first) score=1;; second) score=2;; esac
    success=true; error=''
    if [ "$db_measurement_profile" = full ]; then
        jq -e '.action=="recommend_verified" and .phase=="full_verify" and .measurementProfile=="full" and .recommendation==null and .pairResult==null and .selectionComplete==false and .fullVerificationComplete==false' "$work/state/status.json" >/dev/null || fail 'sampled winner exposed while full verification ran'
        [ "$(wc -l < "$work/endpoints")" = 5 ] || fail 'verified mode skipped complete endpoint screen'
        [ "$db_probe_deadline" -gt "$(( $(date +%s)+90 ))" ] || fail 'full verification retained short sample budget'
        printf '%s|%s\n' "$2" "$4" >> "$work/full-attempts"
        case "$verified_fixture" in
            fallback) [ "$2" != first ] || { success=false; error=section_dns_failed; };;
            all_failed) success=false; error=service_transport_failed;;
            late_winner) case "$2" in first|second) success=false; error=section_dns_failed;; esac;;
            infrastructure) success=false; error=child_config_invalid;;
            cancelled) : > "$work/state/cancel";;
            changed) : > "$work/changed";;
        esac
    fi
    db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" "$success" "$5" | jq --argjson score "$score" --arg profile "$db_measurement_profile" --arg error "$error" --argjson reliable "$success" '.measurementProfile=$profile|.httpsTested=true|.stats={reliable:$reliable,averageMs:$score,scoreMs:$score,retryCount:0}|.sectionResults=[]|.error=(if $error=="" then null else $error end)')"
}
run() {
    rm -f "$work/changed" "$work/state/cancel"
    : > "$work/full-attempts"; : > "$work/endpoints"
    db_report_id=verified-fixture; db_action=recommend_verified; db_deadline=$(( $(date +%s)+300 ))
    db_recommend
}
(
    DB_PROOF="$work/failed-proof.json"
    jq() { return 1; }
    if db_write_proof '{}' stable; then fail 'failed proof serialization reported success'; fi
    [ ! -s "$DB_PROOF" ] || fail 'failed proof serialization published a proof'
)
verified_fixture=fallback
run || fail 'ranked full verification with fallback failed'
db_status | jq -e '.action=="recommend_verified" and .state=="done" and .fullVerificationComplete and .selectionComplete and .comparisonComplete and .measurementProfile=="full" and .recommendationMode=="verified" and .recommendation==.pairResult and .recommendation.id=="second" and .recommendation.success and .recommendation.stats.reliable and .recommendation.automaticEligible and .recommendation.rechecked and .recommendation.measurementProfile=="full" and .fullVerificationAttempts==2 and (.fullVerificationResults|length)==2 and .fullVerificationResults[0].error=="section_dns_failed" and (.pairResults|all(.measurementProfile=="minute_sample"))' >/dev/null || fail 'verified winner or preliminary/full separation untruthful'
db_proof_valid udp second 8.8.8.8 1.1.1.1 udp || fail 'full verified exact winner proof rejected'
if db_proof_valid udp first 1.1.1.1 1.1.1.1 udp; then fail 'sampled leader proof accepted'; fi
cp "$DB_PROOF" "$work/proof.original"; cp "$DB_REPORT" "$work/report.original"
for age in 301 3600 86400 604800; do
    jq --argjson time "$(( $(date +%s)-age ))" '.testedAt=$time' "$work/proof.original" > "$DB_PROOF"
    db_proof_valid udp second 8.8.8.8 1.1.1.1 udp || fail "full winner rejected only because $age seconds passed"
done
for invalid in missing_time malformed_time fractional_time future fingerprint sampled changed_winner running incomplete missing_full_result; do
    cp "$work/proof.original" "$DB_PROOF"; cp "$work/report.original" "$DB_REPORT"
    case "$invalid" in
        missing_time) jq '.testedAt=0' "$DB_PROOF" > "$work/invalid"; mv "$work/invalid" "$DB_PROOF";;
        malformed_time) jq '.testedAt="today"' "$DB_PROOF" > "$work/invalid"; mv "$work/invalid" "$DB_PROOF";;
        fractional_time) jq '.testedAt=1.5' "$DB_PROOF" > "$work/invalid"; mv "$work/invalid" "$DB_PROOF";;
        future) jq --argjson time "$(( $(date +%s)+5 ))" '.testedAt=$time' "$DB_PROOF" > "$work/invalid"; mv "$work/invalid" "$DB_PROOF";;
        fingerprint) : > "$work/changed";;
        sampled) jq '.pair.measurementProfile="minute_sample"' "$DB_PROOF" > "$work/invalid"; mv "$work/invalid" "$DB_PROOF";;
        changed_winner) jq '.recommendation.bootstrapDnsServer="8.8.8.8"' "$DB_REPORT" > "$work/invalid"; mv "$work/invalid" "$DB_REPORT";;
        running) jq '.state="running"' "$DB_REPORT" > "$work/invalid"; mv "$work/invalid" "$DB_REPORT";;
        incomplete) jq '.fullVerificationComplete=false' "$DB_REPORT" > "$work/invalid"; mv "$work/invalid" "$DB_REPORT";;
        missing_full_result) jq '.fullVerificationResults=[]' "$DB_REPORT" > "$work/invalid"; mv "$work/invalid" "$DB_REPORT";;
    esac
    if db_proof_valid udp second 8.8.8.8 1.1.1.1 udp; then fail "unsafe verified proof accepted: $invalid"; fi
    rm -f "$work/changed"
done
(
    cp "$work/report.original" "$DB_STATUS"
    db_cancel >/dev/null
    # Simulate a final atomic publication overtaking the cancel status write.
    cp "$work/report.original" "$DB_STATUS"
    cp "$work/proof.original" "$DB_PROOF"
    db_status | jq -e '.state=="cancelled" and .recommendation==null and .pairResult==null and .selectionComplete==false and .fullVerificationComplete==false' >/dev/null || fail 'late done publication hid cancellation'
    if db_proof_valid udp second 8.8.8.8 1.1.1.1 udp; then fail 'cancelled late proof accepted'; fi
)
verified_fixture=late_winner
run || fail 'full queue stopped after two sampled leaders failed'
db_status | jq -e '.recommendation.id=="third" and .fullVerificationAttempts==4 and (.pairResults|any(.id=="third" and .rechecked==null)) and .fullVerificationComplete' >/dev/null || fail 'unrechecked automatic finalist omitted from full queue'
(
    rm -f "$DB_DIR/cancel"
    db_action=pair_test; db_measurement_profile=full
    eval "$(sed -n '/^db_write_proof()/,/^}/p' "$repo/openwrt/podkop-dns-benchmark" | sed '1s/db_write_proof/db_write_proof_real/')"
    db_write_proof() { db_cancel >/dev/null; db_write_proof_real "$@"; }
    db_check_pair() { db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" true "$5" | jq '.measurementProfile="full"|.stats={reliable:true}|.error=null')"; }
    if db_pair_test udp second 8.8.8.8 1.1.1.1 udp; then fail 'cancel during manual full proof publication recreated success'; fi
    [ ! -s "$DB_PROOF" ] || fail 'cancel during manual full proof publication retained proof'
    db_status | jq -e '.state!="done" and .pairResult.success==false and .error=="cancelled"' >/dev/null || fail 'manual full cancellation remained successful'
)
(
    eval "$(sed -n '/^db_write_proof()/,/^}/p' "$repo/openwrt/podkop-dns-benchmark" | sed '1s/db_write_proof/db_write_proof_real/')"
    db_write_proof() { db_cancel >/dev/null; db_write_proof_real "$@"; }
    verified_fixture=fallback
    if run; then fail 'cancel during proof publication recreated completed verified result'; fi
    [ ! -s "$DB_PROOF" ] || fail 'cancel during proof publication retained verified proof'
    db_status | jq -e '.fullVerificationComplete==false and .selectionComplete==false and .recommendation==null and .error=="cancelled"' >/dev/null || fail 'cancelled final verification remained complete'
)
for verified_fixture in all_failed infrastructure cancelled changed; do
    if run 2> "$work/context-error"; then fail 'failed full verification selected a sampled winner'; fi
    db_status | jq -e '.recommendation==null and .pairResult==null and .selectionComplete==false and .fullVerificationComplete==false and .state!="done"' >/dev/null || fail 'failed full verification granted selection'
    [ ! -s "$DB_PROOF" ] || fail 'failed verified run retained apply proof'
    error="$(db_status | jq -r '.error')"
    case "$verified_fixture:$error" in all_failed:no_fully_verified_pairs|infrastructure:child_config_invalid|cancelled:cancelled|changed:configuration_changed) :;; *) fail "wrong verified error $verified_fixture:$error";; esac
    if [ "$verified_fixture" != all_failed ]; then [ "$(wc -l < "$work/full-attempts")" = 1 ] || fail 'infrastructure/context failure advanced to another candidate'; fi
    [ -z "$db_pool_pids" ] || fail 'verified stage leaked owned workers'
done
echo 'PASS: verified full fallback, hidden sampled winner, context-bound proof without age expiry and fail-closed errors'
