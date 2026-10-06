#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_DNS_OPTIMIZER_STATE_DIR="$work/optimizer-state" PODKOP_DNS_OPTIMIZER_PERSIST_DIR="$work/optimizer-persist"
export PODKOP_MUTATION_LOCK_DIR="$work/mutation" PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/legacy"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
uci() { case "$*" in *export*) echo 'config settings';; *changes*) :;; *) return 1;; esac; }
db_busy() { return 1; }
db_reload_busy() { return 1; }
db_prepare
db_status | jq -e '.state=="idle" and .results==[]' >/dev/null
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
uci() { case "$*" in *export*) echo 'changed config';; *changes*) :;; *) return 1;; esac; }
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8; then fail 'stale config proof allowed'; fi
uci() { case "$*" in *export*) echo 'config settings';; *changes*) :;; *) return 1;; esac; }
jq '.testedAt=0' "$DB_PROOF" > "$work/expired"; mv "$work/expired" "$DB_PROOF"
if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8; then fail 'expired proof allowed'; fi
db_make_config doh cloudflare-dns.com/dns-query 8.8.8.8 "$work/child.json"
jq -e '.dns.servers[0].type=="udp" and .dns.servers[1].type=="https" and .dns.servers[1].domain_resolver=="bootstrap" and .inbounds[0].listen=="127.0.0.1" and .route.rules[0].action=="hijack-dns"' "$work/child.json" >/dev/null
jq -e '.route.default_mark==2097152' "$work/child.json" >/dev/null || fail 'isolated DNS child lacks the native Podkop WAN bypass mark'
db_child_start() { :; }; db_child_stop() { :; }
http_mock_mode=ok
curl() {
    local output='' endpoint='' previous='' argument
    for argument in "$@"; do
        case "$argument" in --proxy|--noproxy) return 22;; esac
        if [ "$previous" = -o ]; then output="$argument"; fi
        case "$argument" in https://*) endpoint="$argument";; esac
        previous="$argument"
    done
    printf '%064d' 0 > "$output"
    if [ "$http_mock_mode" = partial ]; then printf '200'; return 18; fi
    if [ "$http_mock_mode" = denied ]; then printf '403'; return 0; fi
    case "$endpoint" in */v1/models) printf '401';; *) printf '206';; esac
}
db_transport_guards || fail 'HTTPS guards force isolated WAN instead of current Podkop route'
http_mock_mode=denied
if db_transport_guards; then fail 'required HTTP403 was accepted'; fi
http_mock_mode=partial
if db_transport_guards; then fail 'partial HTTP200 with curl failure was accepted'; fi
jq -e '.reason=="curl_failed" and .httpStatus=="200" and .bytes==64 and .path=="current_podkop" and (.url|startswith("https://"))' "$DB_DIR/transport-error.json" >/dev/null
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
db_status | jq -e '.state=="done" and (.results|all(.protocol=="dot")) and (.bootstrapResults|any(.provider=="Yandex" and .reliable)) and (.results|all(.reliable|not))' >/dev/null
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
save_previous_dns() { :; }
restart_podkop() { echo restart >> "$work/restarts"; }
validate_podkop_dns() { return 0; }
validate_google_play_transport() { return 0; }
validate_chatgpt_transport() { return 0; }
db_apply udp cloudflare 1.1.1.1 8.8.8.8
podkop_mutation_lock_release
db_status | jq -e '.state=="done" and .action=="apply"' >/dev/null
[ "$(wc -l < "$work/uci-writes")" = 4 ] || fail 'apply did not write exactly the requested pair and slot'
[ "$(wc -l < "$work/restarts")" = 1 ] || fail 'explicit apply did not restart once'
if db_apply udp cloudflare 1.1.1.1 8.8.8.8; then fail 'consumed proof allowed second apply'; fi
podkop_mutation_lock_release
[ "$(wc -l < "$work/uci-writes")" = 4 ] || fail 'unverified apply wrote config'
[ "$(wc -l < "$work/restarts")" = 1 ] || fail 'unverified apply restarted Podkop'
echo 'PASS: PE DNS pair proof, isolation config, truthful failure, cancel and lock guards'
