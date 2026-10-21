#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ "${1:-}" = __signal ]; then work="$2"; else work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; fi
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_DNS_OPTIMIZER_STATE_DIR="$work/optimizer-state" PODKOP_DNS_OPTIMIZER_PERSIST_DIR="$work/optimizer-persist"
export PODKOP_DNS_APPLY_BACKUP_DIR="$work/dns-apply"
export PODKOP_MUTATION_LOCK_DIR="$work/mutation" PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/legacy"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
# External command fixtures are shell functions; keep them inside this shell.
# Real timeout behavior is exercised by test_pe_dns_resource_safety.sh.
timeout() { shift; "$@"; }
anime_probes="$(write_community_service_probes anime)"
printf '%s\n' "$anime_probes" | grep -Fx 'community|anime|shikimori.io' >/dev/null || fail 'anime probe must use the current Shikimori domain'
if printf '%s\n' "$anime_probes" | grep -F 'shikimori.one' >/dev/null; then fail 'retired Shikimori domain is still required by DNS checks'; fi
ai_probes="$(write_community_service_probes google_ai)"
if printf '%s\n' "$ai_probes" | grep -E 'gemini\.|generativelanguage\.' >/dev/null; then fail 'DNS benchmark must not gate DNS on AI service availability'; fi
printf '%s\n' "$ai_probes" | grep -Fx 'community|google_ai|www.google.com' >/dev/null || fail 'Google AI section needs a neutral connectivity sample'
if [ "${1:-}" = __signal ]; then
    signal="$3"; rollback_failure="$4"; phase="$5"
    mkdir -p "$work"
    echo original > "$work/original.json"; cp "$work/original.json" "$work/uci.json"
    uci() { case "$*" in *export*) echo 'config settings';; *changes*) :;; *) return 1;; esac; }
    db_busy() { return 1; }; db_reload_busy() { return 1; }
    db_load_apply_helper() { :; }
    dns_apply_worker() {
        trap '' INT HUP
        trap '
          trap "" INT TERM HUP
          [ -d "$PODKOP_MUTATION_LOCK_DIR" ] && [ -d "$DB_LOCK" ] || exit 99
          if [ "$phase" = repeated_signal ]; then kill -TERM "$$"; fi
          if [ "$rollback_failure" = yes ]; then
            echo "{\"success\":false,\"error\":\"rollback_failed\",\"restored\":false}"
          else
            cp "$work/original.json" "$work/uci.json"
            echo "{\"success\":false,\"error\":\"interrupted_rolled_back\",\"restored\":true}"
          fi
          exit 130
        ' TERM
        echo candidate > "$work/uci.json"
        kill -"$signal" "$$"
        while :; do sleep 0.05; done
    }
    db_prepare; db_report_id=signal-proof
    db_pair_json="$(db_pair_object udp cloudflare 1.1.1.1 8.8.8.8 true)"
    db_state done pair_test verified 100 1 1 ''; cp "$DB_STATUS" "$DB_REPORT"; db_write_proof "$db_pair_json"
    mkdir "$DB_LOCK"; : > "$DB_DIR/start.ready"
    db_worker apply udp cloudflare 1.1.1.1 8.8.8.8
    fail 'interrupted mutation returned without exiting'
fi
uci() { case "$*" in *export*) echo 'config settings';; *changes*) :;; *) return 1;; esac; }
db_busy() { return 1; }
db_reload_busy() { return 1; }
db_prepare
db_status | jq -e '.state=="idle" and .results==[]' >/dev/null
mkdir -p "$PODKOP_DNS_APPLY_BACKUP_DIR"
printf '%s\n' transaction.test > "$PODKOP_DNS_APPLY_BACKUP_DIR/pending"
db_status | jq -e '.backupAvailable==true' >/dev/null || fail 'pending DNS recovery is hidden by status'
mv "$PODKOP_DNS_APPLY_BACKUP_DIR/pending" "$PODKOP_DNS_APPLY_BACKUP_DIR/latest"
db_status | jq -e '.backupAvailable==true' >/dev/null || fail 'latest DNS transaction is hidden by status'
rm "$PODKOP_DNS_APPLY_BACKUP_DIR/latest"
db_status | jq -e '.backupAvailable==false' >/dev/null || fail 'missing DNS transaction reported available'
db_validate_pair udp cloudflare 1.1.1.1 8.8.8.8 || fail 'valid pair rejected'
if db_validate_pair udp yandex 77.88.8.8 1.1.1.1; then fail 'Yandex primary accepted'; fi
if db_validate_pair doh bad 'host;touch /tmp/no' 1.1.1.1; then fail 'unsafe endpoint accepted'; fi
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8; then fail 'unverified apply allowed'; fi
db_report_id=report-one
db_work="$work"
db_pair_json="$(db_pair_object udp cloudflare 1.1.1.1 8.8.8.8 true)"
db_state done pair_test verified 100 1 1 ''
cp "$DB_STATUS" "$DB_REPORT"
db_write_proof "$db_pair_json"
db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 || fail 'fresh proof rejected'
if db_proof_valid udp cloudflare 1.0.0.1 8.8.8.8; then fail 'different pair allowed'; fi
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 tcp; then fail 'different bootstrap protocol allowed'; fi
uci() { case "$*" in *export*) echo 'changed config';; *changes*) :;; *) return 1;; esac; }
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8; then fail 'stale config proof allowed'; fi
uci() { case "$*" in *export*) echo 'config settings';; *changes*) :;; *) return 1;; esac; }
cp "$DB_PROOF" "$work/proof.saved"
for age in 301 3600 86400 604800; do
    jq --argjson time "$(( $(date +%s)-age ))" '.testedAt=$time' "$work/proof.saved" > "$DB_PROOF"
    db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 || fail "unchanged verified pair rejected after waiting $age seconds"
done
jq '.testedAt=0' "$DB_PROOF" > "$work/expired"; mv "$work/expired" "$DB_PROOF"
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8; then fail 'missing verification timestamp allowed'; fi
db_make_config doh cloudflare-dns.com/dns-query 8.8.8.8 "$work/child.json"
jq -e '.dns.servers[0].type=="udp" and .dns.servers[1].type=="https" and .dns.servers[1].domain_resolver=="bootstrap" and .inbounds[0].listen=="127.0.0.1" and .route.rules[0].action=="hijack-dns"' "$work/child.json" >/dev/null
jq -e '.route.default_mark==2097152' "$work/child.json" >/dev/null || fail 'isolated DNS child lacks the native Podkop WAN bypass mark'
db_query() { echo NXDOMAIN; }
db_deadline=$(( $(date +%s)-1 ))
db_measure | jq -e '.error=="measurement_timeout" and .totalQueries==0 and .nxdomainOk==false' >/dev/null || fail 'expired deadline still queried NXDOMAIN or lost timeout reason'
: > "$work/main"
bootstrap_stats="$(db_measure_bootstrap || true)"
[ -n "$bootstrap_stats" ] || fail 'bootstrap timeout stopped worker without structured reason'
printf '%s' "$bootstrap_stats" | jq -e '.error=="measurement_timeout" and .reliable==false' >/dev/null || fail 'bootstrap timeout reason lost'
db_deadline=0
db_child_start() { :; }; db_child_stop() { :; }
http_mock_mode=ok
curl() {
    local output='' endpoint='' previous='' argument
    for argument in "$@"; do
        if [ "$previous" = --proxy ] && [ "$argument" != socks5h://127.0.0.1:19554 ]; then return 22; fi
        if [ "$previous" = --noproxy ] && [ -n "$argument" ]; then return 22; fi
        if [ "$previous" = -o ]; then output="$argument"; fi
        case "$argument" in https://*) endpoint="$argument";; esac
        previous="$argument"
    done
    printf '%064d' 0 > "$output"
    if [ "$http_mock_mode" = partial ]; then printf '200'; return 18; fi
    if [ "$http_mock_mode" = denied ]; then printf '403'; return 0; fi
    case "$endpoint" in */v1/models) printf '401';; *) printf '206';; esac
}
db_transport_guards || fail 'HTTPS guards do not use isolated copied Podkop routes'
http_mock_mode=denied
if db_transport_guards; then fail 'required HTTP403 was accepted'; fi
http_mock_mode=partial
if db_transport_guards; then fail 'partial HTTP200 with curl failure was accepted'; fi
jq -e '.reason=="curl_failed" and .httpStatus=="200" and .bytes==64 and .path=="candidate_podkop" and (.url|startswith("https://"))' "$DB_DIR/transport-error.json" >/dev/null
http_mock_mode=ok
db_query() { case "$1" in *.invalid) echo NXDOMAIN;; *) printf 'NOERROR|12\n';; esac; }
db_transport_guards() { return 0; }
db_pair_json='null'; db_results='[]'; db_bootstrap_results='[]'
db_action=pair_test; db_report_id=report-two
db_pair_test udp cloudflare 1.1.1.1 8.8.8.8
db_status | jq -e '.state=="done" and .pairResult.success' >/dev/null
db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 || fail 'successful pair test not recorded'
db_transport_guards() {
    printf '%s\n' '{"url":"https://auth.openai.com/.well-known/openid-configuration","httpStatus":"403","reason":"unexpected_status","bytes":120,"path":"current_podkop"}' > "$DB_DIR/transport-error.json"
    return 1
}
if db_pair_test udp cloudflare 1.1.1.1 8.8.8.8; then fail 'transport guard failure accepted'; fi
db_status | jq -e '.state=="error" and .error=="service_transport_failed" and (.pairResult.success|not) and .pairResult.transportError.httpStatus=="403" and .pairResult.transportError.path=="current_podkop"' >/dev/null
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8; then fail 'failed recheck retained old proof'; fi
db_state running benchmark measuring 0 0 2 ''
db_cancel
db_status | jq -e '.state=="cancelled"' >/dev/null
rm -f "$DB_DIR/cancel"
db_state running apply applying 0 0 1 ''
if db_cancel; then fail 'cancel allowed during mutation'; fi
db_state idle benchmark idle 0 0 0 ''
mkdir "$DB_LOCK"
if db_start benchmark; then fail 'second worker accepted'; fi
rmdir "$DB_LOCK"
db_busy() { return 0; }
if db_start pair_test udp cloudflare 1.1.1.1 8.8.8.8; then fail 'busy Podkop accepted'; fi
db_busy() { return 1; }
uci() {
    case "$*" in
        *dns_optimizer_protocols*) echo dot;;
        *bootstrap_dns_server*) echo 8.8.8.8;;
        *export*) echo 'config settings';;
        *changes*) :;;
        *) return 1;;
    esac
}
db_child_start() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$work/starts"
    [ "$2" != 1.1.1.1 ]
}
db_native_start() { db_child_start "$@"; }
db_query() {
    case "$1" in
        *.invalid) echo NXDOMAIN;;
        play.googleapis.com|chatgpt.com) return 1;;
        *) echo 'NOERROR|12';;
    esac
}
db_results='[]'; db_bootstrap_results='[]'; db_deadline=$(( $(date +%s)+600 ))
db_benchmark
[ "$(head -n1 "$work/starts" | cut -d '|' -f1)" = udp ] || fail 'main measured before bootstrap'
db_status | jq -e '.state=="done" and (.results|all(.protocol=="dot" and .precheckOnly==true and .fullCompatibilityVerified==false and .probeScope=="direct_native_dns_ordering_only")) and (.bootstrapResults|any(.provider=="Yandex" and .reliable))' >/dev/null
grep -q '^dot|8.8.8.8|8.8.8.8$' "$work/starts" || fail 'working configured bootstrap not used for main measurements'
if [ -s "$DB_PROOF" ]; then fail 'benchmark automatically granted apply proof'; fi
db_report_id=report-apply
db_pair_json="$(db_pair_object udp cloudflare 1.1.1.1 8.8.8.8 true)"
db_state done pair_test verified 100 1 1 ''; cp "$DB_STATUS" "$DB_REPORT"
db_write_proof "$db_pair_json"
uci() {
    case "$*" in
        *export*) echo 'config settings';;
        *changes*) :;;
        set*) printf '%s\n' "$*" >> "$work/uci-writes";;
        commit*) :;;
        *) return 1;;
    esac
}
db_load_apply_helper() { :; }
(
    dns_apply_worker() { exit 1; }
    if db_dns_transaction prepare; then fail 'empty failed helper accepted'; fi
    [ "$db_transaction_error" = dns_apply_result_unknown ] || fail 'empty helper result lost error code'
    dns_apply_worker() { echo '{"success":true}'; exit 1; }
    if db_dns_transaction prepare; then fail 'failed helper success-looking output accepted'; fi
) || fail 'helper failure reporting regression'
dns_apply_worker() {
    [ "$PODKOP_DNS_APPLY_LOCK_HELD" = 1 ] && [ -d "$PODKOP_MUTATION_LOCK_DIR" ] || return 1
    printf '%s\n' "$*" >> "$work/apply-calls"
    echo '{"success":true,"restored":false}'
}
restart_podkop() { fail 'DNS-only apply invoked broad Podkop restart'; }
db_apply udp cloudflare 1.1.1.1 8.8.8.8
podkop_mutation_lock_release
db_status | jq -e '.state=="done" and .action=="apply"' >/dev/null
[ "$(cat "$work/apply-calls")" = 'apply udp 1.1.1.1 udp 8.8.8.8' ] || fail 'wrong DNS-only transaction arguments'
[ ! -e "$work/uci-writes" ] || fail 'dispatcher changed UCI outside transaction helper'
if db_apply udp cloudflare 1.1.1.1 8.8.8.8; then fail 'consumed proof allowed second apply'; fi
podkop_mutation_lock_release
[ "$(wc -l < "$work/apply-calls")" = 1 ] || fail 'unverified apply reached helper'
for signal in TERM INT HUP; do
    case_work="$work/signal-$signal"
    if sh "$0" __signal "$case_work" "$signal" no after_commit; then fail 'interrupted apply returned success'; else case_rc=$?; fi
    [ "$case_rc" = 130 ] || fail "unexpected interrupted apply exit $case_rc"
    cmp "$case_work/original.json" "$case_work/uci.json" || fail "$signal after commit left candidate DNS applied"
    jq -e '.state=="error" and .error=="apply_interrupted_rolled_back"' "$case_work/state/status.json" >/dev/null || fail 'interrupted rollback status not explicit'
    [ ! -d "$case_work/mutation" ] && [ ! -d "$case_work/state/lock" ] || fail 'interrupted worker retained locks'
    [ ! -s "$case_work/persist/pair-proof.json" ] || fail 'interrupted mutation retained apply proof'
done
case_work="$work/signal-during-repair"
if sh "$0" __signal "$case_work" TERM no repeated_signal; then fail 'repeated signal returned success'; else case_rc=$?; fi
[ "$case_rc" = 130 ] || fail 'second catchable signal interrupted rollback'
cmp "$case_work/original.json" "$case_work/uci.json" || fail 'second catchable signal left candidate DNS'
case_work="$work/signal-failed-rollback"
if sh "$0" __signal "$case_work" TERM yes after_commit; then fail 'failed interrupted rollback returned success'; else case_rc=$?; fi
[ "$case_rc" = 130 ] || fail 'failed interrupted rollback exit differs'
jq -e '.state=="error" and .error=="rollback_failed"' "$case_work/state/status.json" >/dev/null || fail 'failed interrupted rollback was hidden'
[ ! -d "$case_work/mutation" ] && [ ! -d "$case_work/state/lock" ] || fail 'failed interrupted rollback retained locks'
echo 'PASS: PE DNS pair proof, isolation config, truthful failure, cancel and lock guards'
