#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v db_light_rank >/dev/null || fail 'two-pair lightweight selection absent'
db_prepare; db_work="$work/run"; mkdir "$db_work"
cat > "$db_work/light-main.json" <<'EOF'
[{"protocol":"udp","id":"bad","dnsServer":"9.0.0.1","family":"bad","reliable":false,"averageMs":1},
 {"protocol":"udp","id":"a","dnsServer":"1.1.1.1","family":"a","reliable":true,"averageMs":5},
 {"protocol":"udp","id":"c","dnsServer":"8.8.8.8","family":"c","reliable":true,"averageMs":10}]
EOF
cat > "$db_work/light-boot.json" <<'EOF'
[{"protocol":"udp","id":"b","server":"9.9.9.9","family":"b","reliable":true,"averageMs":6},
 {"protocol":"udp","id":"d","server":"4.4.4.4","family":"d","reliable":true,"averageMs":11}]
EOF
db_light_rank
jq -e 'length==4 and .[0].id=="a" and all(.[];.id!="bad" and .mainFamily!=.bootstrapFamily)' "$db_work/light-pairs.json" >/dev/null || fail 'ranking or independent bootstrap'
db_light_pick '[]' > "$work/choice"
jq -e '.primary.id=="a" and .secondary.id=="c" and .secondary.bootstrapFamily=="d"' "$work/choice" >/dev/null || fail 'independent reserve absent'
db_light_pick '["udp|a|1.1.1.1|9.9.9.9|udp","udp|a|1.1.1.1|4.4.4.4|udp"]' > "$work/choice"
jq -e '.primary.id=="c" and .secondary==null' "$work/choice" >/dev/null || fail 'failed fastest pair could win'
# A direct-DNS proof is deliberately not an application/HTTPS proof.
# Exercise the actual streaming route gate before isolating the clock/ranking.
db_runtime_path() { echo "$work/runtime.json"; }
db_worker_configs() { :; }
PODKOP_DNS_APPLY_UCI_FILE="$work/podkop"; printf 'config settings\n' > "$work/podkop"
printf '%s\n' '{"dns":{"servers":[{"tag":"dns-server","detour":"direct-out"},{"tag":"bootstrap-dns-server"}]},"outbounds":[{"tag":"direct-out","type":"direct"}]}' > "$work/runtime.json"
db_light_context >/dev/null || fail 'direct DNS route rejected'
sed 's/"type":"direct"/"type":"socks"/' "$work/runtime.json" > "$work/wrong.json"
mv "$work/wrong.json" "$work/runtime.json"
! db_light_context >/dev/null || fail 'proxy DNS route falsely native-verified'
db_light_probe() { echo '{"success":true,"averageMs":7,"httpsTested":false}'; }
db_light_context() { echo stable; }
db_light_collect() { :; }
db_production_capture() { :; }; db_production_safe() { :; }
db_child_start() { fail 'started second engine'; }
uci() { fail 'selection used UCI mutations or pending view'; }
export PODKOP_DIAG_UPTIME_FILE="$work/clock" PODKOP_DIAG_MEMDOC_FILE="$work/none" PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/mem"
printf '100.0 0\n' > "$work/clock"; printf 'MemAvailable: 65536 kB\n' > "$work/mem"
db_action=select; db_report_id=fixture
db_light_select
jq -e '.state=="done" and .selectionComplete and (.partial|not) and .recommendation.id=="a" and .secondaryRecommendation.id=="c" and .scope=="direct_dns_pair" and .httpsTested==false and .fullCompatibilityVerified==false and .budgetSeconds==60' "$DB_REPORT" >/dev/null || fail 'two-pair result/scope'
db_light_proof_valid fixture || fail 'current proof rejected'
db_status() { cat "$DB_REPORT"; }
db_light_legacy_status | jq -e '.action=="benchmark" and .state=="success" and (.recommendation|type)=="object" and (.secondaryRecommendation|type)=="object"' >/dev/null || fail 'desktop public contract'
printf '401.0 0\n' > "$work/clock"
! db_light_proof_valid fixture || fail 'expired proof accepted'
printf '100.0 0\n' > "$work/clock"
db_light_probe() { printf '160.0 0\n' > "$work/clock"; echo '{"success":true,"averageMs":1}'; }
db_light_select
jq -e '.partial and (.selectionComplete|not) and .recommendation==null' "$DB_REPORT" >/dev/null || fail 'deadline conferred proof'
! db_light_proof_valid fixture || fail 'partial report accepted'
db_light_legacy_status | jq -e '.action=="benchmark" and .state=="error" and .recommendation==null' >/dev/null || fail 'partial desktop result reported as success'
echo 'PASS: two independent DNS pairs, failed-fastest exclusion, separate expiring proof and honest deadline/scope'
