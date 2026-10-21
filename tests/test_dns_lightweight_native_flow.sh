#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/mem" PODKOP_DIAG_MEMDOC_FILE="$work/absent"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir "$db_work"
printf 'MemAvailable: 65536 kB\n' > "$work/mem"
db_runtime_path() { echo "$work/runtime.json"; }
db_worker_configs() { :; }
PODKOP_DNS_APPLY_UCI_FILE="$work/podkop"; printf "config settings 'settings'\n" > "$work/podkop"
printf '%s\n' '{"dns":{"servers":[{"tag":"dns-server","detour":"direct-out"},{"tag":"bootstrap-dns-server"}]},"outbounds":[{"tag":"direct-out","type":"direct"}]}' > "$work/runtime.json"
db_production_capture() { :; }; db_production_safe() { :; }
db_child_start() { fail 'second engine started'; }
uci() {
 case "$*" in
  *get*podkop.settings.dns_optimizer_protocols|*get*podkop.settings.dns_optimizer_bootstrap_protocols) echo udp;;
  *get*) return 1;;
  *changes*) :;;
  *) fail 'unexpected UCI access';;
 esac
}
# Only the external DNS executable is replaced. Catalog, deadline/admission,
# endpoint parsing, answer validation, ranking and confirmations remain real.
db_native_command() {
 printf '%s\n' "$*" >> "$work/queries"
 case "$*" in
  *'@1.1.1.1 '*) return 28;;
  *'.invalid '*) printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n';;
  *) printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; ANSWER SECTION:\nexample.com. 60 IN A 93.184.215.14\n\n;; Query time: 7 msec\n';;
 esac
}
db_action=select; db_report_id=native-fixture
db_light_select
jq -e '.selectionComplete and (.partial|not) and .recommendation.success and .secondaryRecommendation.success and .httpsTested==false and .elapsedSeconds<60 and .recommendation.dnsServer!="1.1.1.1" and .secondaryRecommendation.dnsServer!="1.1.1.1"' "$DB_REPORT" >/dev/null || fail 'actual native workflow did not select two working pairs'
db_light_proof_valid native-fixture || fail 'actual workflow proof rejected'
queries="$(wc -l < "$work/queries")"; [ "$queries" -le 80 ] || fail 'query count unbounded'
bytes="$(du -sk "$work" | awk '{print $1}')"; [ "$bytes" -le 2048 ] || fail 'temporary data exceeds 2 MiB'
[ "$(wc -c < "$DB_REPORT")" -le 131072 ] || fail 'report exceeds 128 KiB'
printf 'Native fixture: elapsed=%ss queries=%s temp=%sKiB report=%sbytes\n' "$(jq -r .elapsedSeconds "$DB_REPORT")" "$queries" "$bytes" "$(wc -c < "$DB_REPORT")"
db_action=light_pair; db_report_id=manual-fixture
db_light_manual udp google 8.8.8.8 9.9.9.9 udp
jq -e '.action=="light_pair" and .pairResult.success and .budgetSeconds==12 and .selectionComplete==false' "$DB_STATUS" >/dev/null || fail 'manual pair did not finish'
[ ! -e "$DB_PERSIST/light-pairs-proof.json" ] || fail 'manual test retained apply permission'
printf 'MemAvailable: 28000 kB\n' > "$work/mem"
before="$(wc -l < "$work/queries")"
! db_light_select || fail 'low memory admitted'
[ "$(wc -l < "$work/queries")" = "$before" ] || fail 'low memory still sends requests'
echo 'PASS: real catalog/native path, failed endpoint exclusion, two confirmations, manual pair, bounded files and RAM refusal'
