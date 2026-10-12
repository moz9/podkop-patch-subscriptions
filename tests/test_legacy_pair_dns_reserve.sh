#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer" PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare; db_work="$work/run"; mkdir -p "$db_work"
# Router BusyBox tr does not implement POSIX character classes. Refuse them
# at this boundary so provider identity must use portable explicit ranges.
tr() {
    case "${1:-}" in *'[:upper:]'*|*'[:lower:]'*) return 1;; esac
    command tr "$@"
}
[ "$(db_provider_family 'Cloudflare')" = cloudflare ] || fail 'provider normalization needs unsupported tr classes'
[ "$(db_provider_family 'ControlD Free p0')" = controld ] || fail 'same provider variants are not grouped'
configured_active_slot() { echo primary; }
read_configured_pair() { echo 'dot|cloudflare-dns.com|1.1.1.1'; }
uci() { case "$*" in *bootstrap_dns_type) echo udp;; set*|commit*|delete*) fail 'reserve changed UCI';; *) return 1;; esac; }
[ "$(db_endpoint_provider main dot one.one.one.one)" = cloudflare ] || fail 'Cloudflare hostname alias lost provider'
[ "$(db_endpoint_provider main udp 76.76.2.0)" = controld ] || fail 'Control D UDP family mismatch'
[ "$(db_endpoint_provider main doh freedns.controld.com/p0)" = controld ] || fail 'Control D DoH family mismatch'
if db_endpoint_provider main udp 192.0.2.1; then fail 'unknown address guessed an independent provider'; fi
printf '%s\n' '[{"mainFamily":"cloudflare","bootstrapFamily":"google"},{"mainFamily":"google","bootstrapFamily":"cloudflare"},{"mainFamily":"google","bootstrapFamily":"google"},{"mainFamily":"controld","bootstrapFamily":"yandex"},{"mainFamily":"google","bootstrapFamily":"controld"}]' > "$db_work/all-pairs.json"
db_reserve_filter || fail 'independent reserve filtering failed'
jq -e 'length==2 and all(.mainFamily!="cloudflare" and .bootstrapFamily!="cloudflare" and .mainFamily!=.bootstrapFamily)' "$db_work/all-pairs.json" >/dev/null || fail 'reserve shares outage provider or same-provider endpoints'
[ "$db_current_primary_provider" = cloudflare ] && [ "$db_current_bootstrap_provider" = cloudflare ] || fail 'current providers not captured'
read_configured_pair() { echo 'udp|192.0.2.1|1.1.1.1'; }
if db_reserve_filter; then fail 'unknown current provider allowed unproven independence'; fi
[ "$db_child_error" = current_provider_unknown ] || fail 'unknown provider lacks actionable failure'
db_action=recommend_reserve
db_is_recommend && db_is_staged && db_is_verified || fail 'reserve does not use staged full verification'
db_report_id=reserve-fixture; db_action=recommend_reserve; db_deadline=$(( $(date +%s)+300 ))
read_configured_pair() { echo 'dot|cloudflare-dns.com|1.1.1.1'; }
uci() { case "$*" in *dns_optimizer_protocols|*dns_optimizer_bootstrap_protocols) echo udp;; *bootstrap_dns_type) echo udp;; set*|commit*|delete*) fail 'reserve changed UCI';; *) return 1;; esac; }
db_fingerprint() { echo stable; }; db_fast_context() { return 0; }; db_runtime_safe() { return 0; }; db_validate_pair() { return 0; }; db_parallel_limit() { echo 2; }
db_prepare_runtime_cache() { return 0; }
write_main_candidates() { printf '%s\n' 'cloudflare|Cloudflare|1.1.1.1|unfiltered' 'google|Google|8.8.8.8|unfiltered' 'controld_unfiltered|Control D Unfiltered|76.76.2.0|unfiltered' > "$2"; }
write_bootstrap_candidates() { printf '%s\n' 'cf|Cloudflare DNS|1.1.1.1|unfiltered' 'ya|Yandex DNS|77.88.8.1|unfiltered' 'gg|Google DNS|8.8.8.8|unfiltered' > "$1"; }
db_child_start() { :; }; db_child_stop() { :; }
# Independent endpoint screening uses the native transport path.
db_native_start() { db_child_start "$@"; }
db_query() { case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|10';; esac; }
probe_bootstrap() {
    success=true; [ "$2" != 77.88.8.1 ] || success=false
    jq -cn --arg p "$1" --arg s "$2" --argjson ok "$success" '{success:$ok,protocol:$p,server:$s,error:(if $ok then "" else "bootstrap_query_failed" end),checks:[{domain:"example.com",success:$ok,reason:(if $ok then "" else "no_response" end)}]}'
    [ "$success" = true ]
}
db_check_pair() {
    score=1; [ "$4" = 77.88.8.1 ] || score=2
    if [ "$db_measurement_profile" = full ]; then printf '%s|%s\n' "$3" "$4" >> "$work/full-attempts"; fi
    db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" true "$5" | jq --argjson score "$score" --arg profile "$db_measurement_profile" '.measurementProfile=$profile|.httpsTested=true|.stats={reliable:true,averageMs:$score,scoreMs:$score,retryCount:0,successCount:2,totalQueries:2}|.sectionResults=[]|.error=null')"
}
db_recommend || fail 'reserve staged full workflow failed'
db_status | jq -e '.state=="done" and .action=="recommend_reserve" and .reserve and .fullVerificationComplete and .recommendationMode=="reserve" and .recommendation.provider=="controld" and .recommendation.bootstrapProvider=="google" and .recommendationBootstrapTest.success==true and .fullVerificationAttempts>=2 and any(.fullVerificationResults[]; .error=="bootstrap_query_failed")' >/dev/null || fail 'reserve failed bootstrap winner was not skipped'
[ ! -s "$DB_PROOF" ] || fail 'reserve recommendation armed current primary apply'
[ -s "${DB_RESERVE_PROOF:-$DB_PERSIST/reserve-proof.json}" ] || fail 'reserve recommendation has no independent backend persistence proof'
db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp || fail 'exact fully verified reserve not saveable'
if db_reserve_proof_valid udp google 8.8.8.8 8.8.8.8 udp; then fail 'different tuple accepted for reserve save'; fi
db_fingerprint() { echo changed; }
if db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'stale runtime proof accepted'; fi
db_fingerprint() { echo stable; }
cp "$DB_REPORT" "$work/prior-report.json"

# Report, pair and successful bootstrap must all agree with the private proof.
jq '.recommendationBootstrapTest.success=false' "$work/prior-report.json" > "$DB_REPORT"
if db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'failed bootstrap report accepted'; fi
cp "$work/prior-report.json" "$DB_REPORT"
jq '.recommendation.dnsServer="8.8.4.4"' "$work/prior-report.json" > "$DB_REPORT"
if db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'different report winner accepted'; fi
cp "$work/prior-report.json" "$DB_REPORT"

# Persist only the reserve stanza, never unrelated saved/pending values.
command -v db_reserve_save >/dev/null || fail 'independent reserve persistence backend missing'
export PODKOP_DNS_BENCHMARK_APPLY_HELPER="$repo/openwrt/podkop-dns-apply"
export PODKOP_DNS_APPLY_UCI_FILE="$work/podkop"
export PODKOP_MUTATION_LOCK_DIR="$work/mutation.lock" PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/mutation.legacy"
reserve_fixture="$work"
printf '%s\n' '# preserve this comment' "config podkop 'settings'" " option dns_type 'dot'" " option dns_server 'cloudflare-dns.com'" " option bootstrap_dns_server '1.1.1.1'" " option dns_failover_active_slot 'primary'" " option dns_failover_enabled '0'" " option secondary_dns_enabled '0'" " option secondary_dns_server '9.9.9.9'" " option unrelated 'saved'" "config section 'main'" " list mixed_list 'saved-a'" " list mixed_list 'saved-b'" > "$PODKOP_DNS_APPLY_UCI_FILE"
printf '%s\n' "podkop.settings.unrelated='pending'" "podkop.main.mixed_list+='pending-c'" > "$work/pending"
cp -p "$PODKOP_DNS_APPLY_UCI_FILE" "$work/config.before"
cp "$work/pending" "$work/pending.before"
uci() {
    [ "${1:-}" != -q ] || shift
    case "$1" in
      export) [ "${2:-}" != podkop ] || fail 'reserve parsed effective UCI instead of persisted file';
        # Native UCI's tuple parser splits at dots even inside parent paths.
        # Local /tmp/tmp.XXX therefore deliberately requires a no-dot alias.
        case "$2" in *.*) return 1;; esac
        cat "$2";;
      changes) cat "$reserve_fixture/pending";;
      get) case "$2" in *bootstrap_dns_type) echo udp;; *) return 1;; esac;;
      *) fail "reserve attempted live UCI mutation: $*";;
    esac
}
db_reload_busy() { return 1; }
db_reserve_status | jq -e '.saveReady==true and .saveReportId=="reserve-fixture" and .saveError==null' >/dev/null || fail 'backend readiness missing for exact current proof'
cp "$DB_RESERVE_PROOF" "$work/reserve-proof.before"
rm -f "$DB_RESERVE_PROOF"
db_reserve_status | jq -e '.saveReady==false and .saveReportId=="reserve-fixture" and .saveError=="reserve_recheck_required"' >/dev/null || fail 'legacy reserve report falsely armed persistence without backend proof'
[ ! -s "$DB_RESERVE_PROOF" ] || fail 'readiness minted an unproven legacy proof'
cmp "$work/config.before" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'readiness modified saved config'
cmp "$work/pending.before" "$work/pending" || fail 'readiness modified pending config'
cp "$work/reserve-proof.before" "$DB_RESERVE_PROOF"
db_fingerprint() { echo changed; }
db_reserve_status | jq -e '.saveReady==false and .saveError=="stale_reserve_proof"' >/dev/null || fail 'stale fingerprint falsely reported save ready'
db_fingerprint() { echo stable; }
db_action=reserve_save
db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp || fail 'validated reserve did not persist'
podkop_mutation_lock_release
db_reserve_status | jq -e '.success and .reserve.enabled==true and .reserve.dnsType=="udp" and .reserve.dnsServer=="76.76.2.0" and .reserve.bootstrapDnsType=="udp" and .reserve.bootstrapDnsServer=="8.8.8.8" and .reserve.autoFailoverEnabled==false and .reserve.activeSlot=="primary"' >/dev/null || fail 'reserve persisted readback mismatch'
cmp "$work/pending" "$work/pending.before" || fail 'reserve touched unrelated pending drafts'
grep -Fq " option unrelated 'saved'" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'reserve committed pending unrelated option'
grep -Fq '# preserve this comment' "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'reserve discarded unrelated comments'
grep -Fq " list mixed_list 'saved-b'" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'reserve discarded unrelated saved list'
cmp "$DB_REPORT" "$work/prior-report.json" || fail 'save discarded recommendation report'
jq -e '.state=="done" and .action=="reserve_save"' "$DB_STATUS" >/dev/null || fail 'async worker-compatible save result missing'

cp "$PODKOP_DNS_APPLY_UCI_FILE" "$work/config.saved"
printf '%s\n' "podkop.settings.secondary_dns_server='pending.example'" >> "$work/pending"
db_reserve_status | jq -e '.saveReady==false and .saveError=="reserve_pending_conflict"' >/dev/null || fail 'overlapping DNS draft falsely reported save ready'
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'conflicting reserve draft accepted'; fi
podkop_mutation_lock_release
cmp "$PODKOP_DNS_APPLY_UCI_FILE" "$work/config.saved" || fail 'failed reserve save modified config'
jq -e '.error=="reserve_pending_conflict"' "$DB_STATUS" >/dev/null || fail 'conflicting draft lacks clear failure'
cp "$work/pending.before" "$work/pending"
db_fingerprint() { echo changed; }
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'stale reserve saved'; fi
podkop_mutation_lock_release
cmp "$PODKOP_DNS_APPLY_UCI_FILE" "$work/config.saved" || fail 'stale reserve modified config'
db_fingerprint() { echo stable; }

printf '%s\n' "config section 'not_settings'" > "$work/no-settings"
if dns_reserve_fields "$work/no-settings" >/dev/null; then fail 'missing persisted settings returned plausible reserve status'; fi

for key in secondary_dns_enabled secondary_dns_type secondary_dns_server secondary_bootstrap_dns_type secondary_bootstrap_dns_server; do
    dns_reserve_pending_safe "podkop.settings.unrelated='draft'" || fail 'unrelated pending option rejected'
    if dns_reserve_pending_safe "podkop.settings.$key='draft'"; then fail "overlapping reserve draft accepted: $key"; fi
    if dns_reserve_pending_safe "-podkop.settings.$key"; then fail "overlapping deleted reserve option accepted: $key"; fi
done
for key in dns_type dns_server bootstrap_dns_type bootstrap_dns_server dns_failover_enabled dns_failover_active_slot; do
    if dns_reserve_pending_safe "podkop.settings.$key='draft'"; then fail "staged active DNS/failover context accepted: $key"; fi
done
if dns_reserve_pending_safe '-podkop.settings'; then fail 'settings section deletion accepted'; fi
if dns_reserve_pending_safe "@podkop.settings='elsewhere'"; then fail 'settings section rename accepted'; fi

cp "$work/config.saved" "$PODKOP_DNS_APPLY_UCI_FILE"
sed "s/dns_failover_enabled '0'/dns_failover_enabled '1'/" "$PODKOP_DNS_APPLY_UCI_FILE" > "$work/autofailover"
cp "$work/autofailover" "$PODKOP_DNS_APPLY_UCI_FILE"
db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp || fail 'existing auto failover prevented reserve-only save'
podkop_mutation_lock_release
cmp "$work/autofailover" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'identical reserve save changed active/autofailover settings or other bytes'
db_reserve_status | jq -e '.reserve.autoFailoverEnabled==true' >/dev/null || fail 'status falsely reported existing auto failover disabled'
cp "$work/config.saved" "$PODKOP_DNS_APPLY_UCI_FILE"
sed "s/dns_failover_active_slot 'primary'/dns_failover_active_slot 'secondary'/" "$PODKOP_DNS_APPLY_UCI_FILE" > "$work/active-secondary"
cp "$work/active-secondary" "$PODKOP_DNS_APPLY_UCI_FILE"
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'persisted active reserve modified without apply'; fi
podkop_mutation_lock_release
jq -e '.error=="reserve_is_active"' "$DB_STATUS" >/dev/null || fail 'active reserve refusal missing'
cmp "$work/active-secondary" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'active reserve refusal changed saved configuration'
cp "$work/config.saved" "$PODKOP_DNS_APPLY_UCI_FILE"
mv() { case "$1" in */.podkop-reserve.*) return 1;; *) command mv "$@";; esac; }
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'failed atomic rename reported successful save'; fi
podkop_mutation_lock_release
unset -f mv
cmp "$work/config.saved" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'failed atomic rename changed saved configuration'
cmp "$work/pending.before" "$work/pending" || fail 'failed atomic rename changed pending configuration'

# Simulate an external draft edit during staging. The second pending read
# must reject it without replacing the committed config or erasing the draft.
uci() {
    [ "${1:-}" != -q ] || shift
    case "$1" in
      export) cat "$2"; case "$(readlink "$2" 2>/dev/null || printf '%s' "$2")" in */transaction.*/podkop) printf '%s\n' "podkop.main.new_draft='keep'" >> "$reserve_fixture/pending";; esac;;
      changes) cat "$reserve_fixture/pending";;
      get) case "$2" in *bootstrap_dns_type) echo udp;; *) return 1;; esac;;
      *) fail "reserve attempted live UCI mutation: $*";;
    esac
}
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'concurrently edited pending state accepted'; fi
podkop_mutation_lock_release
cmp "$PODKOP_DNS_APPLY_UCI_FILE" "$work/config.saved" || fail 'concurrent draft race replaced config'
grep -Fq "podkop.main.new_draft='keep'" "$work/pending" || fail 'concurrent draft lost'
cp "$work/pending.before" "$work/pending"
uci() {
    [ "${1:-}" != -q ] || shift
    case "$1" in export) cat "$2";; changes) cat "$reserve_fixture/pending";; get) case "$2" in *bootstrap_dns_type) echo udp;; *) return 1;; esac;; *) fail "reserve attempted live UCI mutation: $*";; esac
}
db_fingerprint() {
    if [ -f "$reserve_fixture/fingerprint-seen" ]; then printf '%s\n' " option external_edit 'keep'" >> "$PODKOP_DNS_APPLY_UCI_FILE"; else : > "$reserve_fixture/fingerprint-seen"; fi
    echo stable
}
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'external saved edit during context check overwritten'; fi
podkop_mutation_lock_release
grep -Fq " option external_edit 'keep'" "$PODKOP_DNS_APPLY_UCI_FILE" || fail 'external saved edit during context lost'
db_fingerprint() { echo stable; }
cp "$work/config.saved" "$PODKOP_DNS_APPLY_UCI_FILE"
reserve_size_kb="$(du -k "$PODKOP_DNS_APPLY_UCI_FILE" | awk '{print $1}')"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 1000 500 %s 50%% fixture\n' "$((reserve_size_kb*5+128))"; }
if db_reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'backup capacity undercount ignored eight transaction images'; fi
podkop_mutation_lock_release
unset -f df
jq -e '.error=="insufficient_backup_space"' "$DB_STATUS" >/dev/null || fail 'backup capacity refusal missing'
cmp "$PODKOP_DNS_APPLY_UCI_FILE" "$work/config.saved" || fail 'low-space refusal modified config'
db_cancel >/dev/null
rm -f "$DB_DIR/cancel"
if db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail 'cancelled reserve proof resurrected after another diagnostic'; fi

db_validate_bootstrap_request udp 1.1.1.1 dot cloudflare-dns.com || fail 'valid bootstrap admission rejected'
if db_validate_bootstrap_request doq 1.1.1.1 dot cloudflare-dns.com; then fail 'unsupported admission allowed'; fi
if db_validate_bootstrap_request udp dns.example dot cloudflare-dns.com; then fail 'circular bootstrap admission allowed'; fi
if db_validate_bootstrap_request udp 1.1.1.1 dot 'dns.example;bad'; then fail 'unsafe main host admission allowed'; fi
db_action=bootstrap_test
db_test_bootstrap udp 8.8.8.8 dot cloudflare-dns.com || fail 'standalone bootstrap check failed'
jq -e '.state=="done" and .action=="bootstrap_test" and .bootstrapTest.success and .bootstrapTest.server=="8.8.8.8" and .recommendation==null and .pairResult==null' "$DB_STATUS" >/dev/null || fail 'standalone bootstrap report invalid'
cmp "$DB_REPORT" "$work/prior-report.json" || fail 'bootstrap diagnostic discarded stored pair report'
if db_test_bootstrap udp 77.88.8.1 dot cloudflare-dns.com; then fail 'bootstrap failure accepted'; fi
jq -e '.state=="error" and .bootstrapTest.checks[0].reason=="no_response"' "$DB_STATUS" >/dev/null || fail 'bootstrap failure reason missing'
echo 'PASS: reserve provider independence and fail-closed selection'
