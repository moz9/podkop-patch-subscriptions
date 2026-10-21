#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="${2:-$repo/openwrt/podkop-dns-optimizer}"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "${1:-$repo/openwrt/podkop-dns-benchmark}"
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$DB_DIR" "$DB_PERSIST"; db_work="$work"; db_deadline=$(( $(date +%s)+60 )); db_probe_deadline=0
db_cancel_file="$work/cancel"; db_resource_error_file=''; db_resource_watch_pid=''; db_section_pids=''; db_child_pid=''
printf 'MemAvailable: 39936 kB\n' > "$work/meminfo"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/meminfo"
db_production_safe() { :; }
db_production_capture() { :; }
db_child_start() { fail 'native probe launched private engine'; }
dig() {
    printf '%s\n' "$*" >> "$work/dig.args"
    case "$*" in *hang*) exec sleep 20;; esac
    if [ "${bad_response:-}" = empty ]; then printf ';; ->>HEADER<<- status: NOERROR, id: 1\n;; Query time: 5 msec\n'; return; fi
    if [ "${bad_response:-}" = exit ]; then printf ';; ->>HEADER<<- status: NOERROR, id: 1\nexample.com. 60 IN A 93.184.216.34\n'; return 1; fi
    case "$*" in *'.invalid'*) printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; Query time: 5 msec\n';;
      *) printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; ANSWER SECTION:\nexample.com. 60 IN A 93.184.216.34\n;; Query time: 5 msec\n';; esac
}
db_native_start doh cloudflare-dns.com 77.88.8.8 udp || fail '39MiB native admission'
[ "$(db_query example.com)" = 'NOERROR|5' ] || fail 'DoH native query'
grep -F '@77.88.8.8' "$work/dig.args" >/dev/null || fail 'explicit bootstrap'
grep -F '+tls-hostname=cloudflare-dns.com' "$work/dig.args" >/dev/null || fail 'DoH TLS identity'
grep -F '+https=/dns-query' "$work/dig.args" >/dev/null || fail 'DoH path'
[ "$(db_query test.invalid)" = NXDOMAIN ] || fail 'negative response'
db_native_start dot 1.1.1.1 77.88.8.8 udp || fail 'DoT numeric endpoint'
db_query example.com >/dev/null || fail 'DoT query'
grep -F '+tls' "$work/dig.args" >/dev/null || fail 'DoT protocol'
bad_response=empty
if db_query example.com >/dev/null; then fail 'empty NOERROR accepted'; fi
bad_response=exit
if db_query example.com >/dev/null; then fail 'failed dig with answer accepted'; fi
bad_response=''
touch "$db_cancel_file"
if db_query example.com >/dev/null; then fail 'cancel ignored'; fi
rm "$db_cancel_file"
start="$(date +%s)"
if db_query hang.example >/dev/null; then fail 'hung query accepted'; fi
[ "$(( $(date +%s)-start ))" -le 5 ] || fail 'native timeout unbounded'
sleep 20 >/dev/null 2>&1 & unrelated=$!
(sleep 1; touch "$db_cancel_file") >/dev/null 2>&1 & canceller=$!
start="$(date +%s)"
if db_query hang.example >/dev/null; then fail 'cancelled in-flight query accepted'; fi
wait "$canceller"
[ "$(( $(date +%s)-start ))" -le 3 ] || fail 'in-flight cancel slow'
kill -0 "$unrelated" || fail 'cancel targeted unrelated PID'
kill "$unrelated"; wait "$unrelated" 2>/dev/null || true
rm "$db_cancel_file"
if command -v db_wait_admission >/dev/null 2>&1; then
    start="$(date +%s)"
    if db_wait_admission 40960; then fail 'heavy clone admitted39MiB'; fi
    [ "$(( $(date +%s)-start ))" -le 2 ] || fail 'heavy admission waits45s'
    jq -e '.waiting==false and .requiredKb==40960 and .availableKb==39936' "$work/waiting-memory.json" >/dev/null || fail 'memory admission details'
fi
db_action=recommend_verified
db_fingerprint() { fail 'lightweight mode starts heavy fingerprint'; }
db_prepare_runtime_cache() { fail 'lightweight mode clones graph'; }
uci() { case "$*" in *dns_optimizer_protocols*) echo doh;; *dns_optimizer_bootstrap_protocols*) echo udp;; *bootstrap_dns_server*) echo 77.88.8.8;; *) :;; esac; }
write_main_candidates() { printf 'cloudflare|Cloudflare|cloudflare-dns.com|default\n' > "$2"; }
write_bootstrap_candidates() { printf 'yandex|Yandex|77.88.8.8|default\n' > "$1"; }
candidate_primary_eligible_json() { echo true; }
printf stale > "$DB_PROOF"
db_recommend || fail 'native recommendation status'
jq -e '.state=="done" and .phase=="endpoint_only" and .fullVerificationComplete==false and .selectionComplete==false and .recommendation==null and .memory.availableKb==39936 and (.results|length)==1 and .results[0].probeScope=="direct_native_dns_ordering_only" and .results[0].httpsTested==false' "$DB_STATUS" >/dev/null || fail 'partial result scope'
[ ! -f "$DB_PROOF" ] || fail 'stale proof retained'
echo 'native benchmark: OK'
