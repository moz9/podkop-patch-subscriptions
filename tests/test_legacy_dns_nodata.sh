#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$fixture_dir/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$fixture_dir/persist"
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare; db_work="$fixture_dir/run"; mkdir "$db_work"
db_runtime_safe() { return 0; }
dig() { cat "$fixture_dir/reply"; return "${fixture_exit:-0}"; }
cat_reply() { printf '%s\n' ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1' "$@" ';; Query time: 7 msec' > "$fixture_dir/reply"; }
soa='example. 60 IN SOA ns.example. hostmaster.example. 1 3600 600 86400 60'
cat_reply ';; AUTHORITY SECTION:' "$soa"
[ "$(db_query no-a.example)" = NODATA ] || fail 'NOERROR empty answer with authority SOA misclassified as DNS failure'
cat_reply ';; ANSWER SECTION:' 'no-a.example. 60 IN CNAME alias.example.' ';; AUTHORITY SECTION:' "$soa" ';; ADDITIONAL SECTION:' 'ns.example. 60 IN A 93.184.216.34'
[ "$(db_query no-a.example)" = NODATA ] || fail 'CNAME/SOA plus additional glue was falsely counted as positive A'
for bad in 0.0.0.0 127.0.0.1 198.18.0.1 10.0.0.1; do
  cat_reply ';; ANSWER SECTION:' "bad.example. 60 IN A $bad" ';; AUTHORITY SECTION:' "$soa" ';; ADDITIONAL SECTION:' 'ns.example. 60 IN A 93.184.216.34'
  if db_query bad.example > "$fixture_dir/result"; then fail "unusable ANSWER A accepted: $bad"; fi
  [ "$(cat "$fixture_dir/result")" = 'ERROR|UNUSABLE_ANSWER' ] || fail 'bad ANSWER was reclassified as NODATA'
done
cat_reply ';; AUTHORITY SECTION:' 'example. 60 IN NS ns.example.'
if db_query referral.example >/dev/null; then fail 'NS-only referral accepted as NODATA'; fi
cat_reply ';; ADDITIONAL SECTION:' "$soa"
if db_query missing.example >/dev/null; then fail 'SOA outside authority accepted as NODATA'; fi
cat_reply ';; AUTHORITY SECTION:' "$soa"; fixture_exit=1
if db_query no-a.example >/dev/null; then fail 'failed dig accepted a success-looking negative response'; fi
fixture_exit=0
cat_reply ';; ANSWER SECTION:' 'positive.example. 60 IN A 93.184.216.34' ';; AUTHORITY SECTION:' "$soa"
[ "$(db_query positive.example)" = 'NOERROR|7' ] || fail 'usable ANSWER A lost'

# Every base/bootstrap query still requires positive A; only section guards
# distinguish valid NODATA and omit that domain from HTTPS obligations.
db_query() { case "$1" in *.invalid) echo NXDOMAIN;; *) echo NODATA;; esac; }
write_compatibility_domains() { printf 'base|google_play|no-a.example\n' > "$1"; }
db_action=pair_test; db_measurement_profile=full
db_measure | jq -e '.reliable==false and .successCount==0 and .error=="dns_query_failed"' >/dev/null || fail 'base accepted NODATA as usable A'
db_measure_bootstrap | jq -e '.reliable==false and .successCount==0 and .error=="bootstrap_query_failed"' >/dev/null || fail 'bootstrap accepted NODATA as usable A'
printf '[{"section":"main","dnsPort":19602,"proxyPort":19603}]\n' > "$db_work/sections.json"
db_tested_sections='["main"]'
jq -n '{route:{rules:[{outbound:"main-out",rule_set:["sample"]}],rule_set:[{tag:"sample",type:"inline",rules:[{domain_suffix:["no-a.example","positive.example"]}]}]}}' > "$db_work/child.json"
db_query() { case "$1" in positive.example) echo 'NOERROR|7';; *) echo NODATA;; esac; }
db_transport_guards() { cp "$db_section_endpoints" "$fixture_dir/attempted-https"; }
db_section_guards || fail 'valid NODATA section with positive HTTPS host failed'
printf '%s' "$db_section_results" | jq -e '.[0].success and .[0].dnsCount==4 and .[0].positiveDnsCount==2 and .[0].nodataCount==2 and .[0].httpsCount==1 and .[0].skippedHttps==[{domain:"no-a.example",reason:"nodata_no_a"}] and .[0].failedQueries==[]' >/dev/null || fail 'section NODATA/positive/HTTPS counters or explicit skip wrong'
[ "$(cat "$fixture_dir/attempted-https")" = 'https://positive.example/||reachability' ] || fail 'HTTPS attempted for NODATA domain'
jq '.route.rule_set[0].rules[0].domain_suffix += ["mixed.example"]' "$db_work/child.json" > "$fixture_dir/mixed.json"
cp "$fixture_dir/mixed.json" "$db_work/child.json"
db_query() {
  case "$1" in
    positive.example) echo 'NOERROR|7';;
    mixed.example)
      if [ -e "$fixture_dir/mixed-once" ]; then echo NODATA; else touch "$fixture_dir/mixed-once"; echo 'NOERROR|7'; fi;;
    *) echo NODATA;;
  esac
}
db_section_guards || fail 'mixed repeats lost other positive section proof'
printf '%s' "$db_section_results" | jq -e '.[0].success and .[0].dnsCount==6 and .[0].positiveDnsCount==3 and .[0].nodataCount==3 and .[0].httpsCount==1 and (.[0].skippedHttps|map(.domain)|sort)==["mixed.example","no-a.example"]' >/dev/null || fail 'mixed-repeat domain counted as HTTPS-ready'
[ "$(cat "$fixture_dir/attempted-https")" = 'https://positive.example/||reachability' ] || fail 'HTTPS attempted when one mandatory repeat was NODATA'
jq '.route.rule_set[0].rules[0].domain_suffix -= ["mixed.example"]' "$db_work/child.json" > "$fixture_dir/original.json"
cp "$fixture_dir/original.json" "$db_work/child.json"
db_query() { echo NODATA; }
rm "$fixture_dir/attempted-https"
if db_section_guards; then fail 'all-negative section certified'; fi
printf '%s' "$db_section_results" | jq -e '.[0].error=="section_scope_unverified" and .[0].positiveDnsCount==0 and .[0].httpsCount==0 and .[0].nodataCount==4' >/dev/null || fail 'all-negative section not scope-unverified'
[ ! -e "$fixture_dir/attempted-https" ] || fail 'all-negative section attempted HTTPS'
for failure in NXDOMAIN 'ERROR|SERVFAIL' 'ERROR|UNUSABLE_ANSWER'; do
  db_query() { if [ "$1" = no-a.example ]; then echo "$failure"; else echo 'NOERROR|7'; fi; }
  if db_section_guards; then fail "section DNS failure accepted: $failure"; fi
  printf '%s' "$db_section_results" | jq -e '.[0].error=="section_dns_failed" and (.[0].failedQueries|length)==2' >/dev/null || fail 'negative error lost'
done
echo 'PASS: strict authority-SOA NODATA, no fake/private/glue A proof, base/bootstrap require A, section HTTPS skips explicit and all-negative uncertified'
