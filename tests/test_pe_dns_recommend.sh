#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '#!/bin/sh\n[ "$1" = version ] || exit 1\nprintf "sing-box version fixture\\nTags: with_utls\\n"\n' > "$work/engine"
chmod 700 "$work/engine"
export PODKOP_DNS_BENCHMARK_BIN="$work/engine"
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_DNS_OPTIMIZER_STATE_DIR="$work/optimizer-state" PODKOP_DNS_OPTIMIZER_PERSIST_DIR="$work/optimizer-persist"
export PODKOP_MUTATION_LOCK_DIR="$work/mutation" PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/legacy"
export PODKOP_DNS_BENCHMARK_WORKERS_DIR="$work/workers"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
# OpenWrt jq may be built without ONIGURUMA: fast selection must not depend
# on its optional regex operations (portable shell sed is available instead).
if sed -n '/^db_fast_catalog()/,/^db_recommend()/p' "$repo/openwrt/podkop-dns-benchmark" | grep -Eq '[| (](sub|gsub|test|match|capture|scan|splits)\('; then
    fail 'fast recommendation requires optional jq regex engine'
fi
db_prepare; db_work="$work"; mkdir -p "$work/workers/main" "$work/workers/GEOBLOCK"
db_state idle benchmark fixture_initial 0 0 0 ''
db_status | jq -e '.availableResults==null and .availableBootstrapResults==null' >/dev/null || fail 'unknown catalog hides measured benchmark options'
db_validate_pair doh cloudflare 1.1.1.1 8.8.8.8 || fail 'canonical Cloudflare alias rejected'
db_validate_pair udp google 8.8.8.8 1.0.0.1 || fail 'fresh unmeasured configured candidate rejected'
if db_validate_pair doh cloudflare dns.google 8.8.8.8; then fail 'foreign endpoint passed canonical comparison'; fi
printf 'doh|fixture|Fixture|unreachable.example|unfiltered\n' > "$work/main"
db_query() { case "$1" in unreachable.example) return 1;; *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|12';; esac; }
db_measure_bootstrap | jq -e '.reliable' >/dev/null || fail 'bootstrap precheck requires unrelated main hostname'
db_query() { case "$1" in chatgpt.com) echo 'ERROR|REFUSED'; return 1;; *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|12';; esac; }
db_measure | jq -e '.failedQueries|any(.domain=="chatgpt.com" and .error=="ERROR|REFUSED")' >/dev/null || fail 'failed domain/reason omitted'
uci() { case "$*" in *export*) echo config;; *config_path*) echo "$work/runtime.json";; *changes*) :;; set*|commit*|delete*) fail 'recommend mutated UCI';; *) return 1;; esac; }
jq -n '{dns:{servers:[{tag:"dns-server",type:"udp",server:"9.9.9.9"}],final:"dns-server"},outbounds:[{tag:"main-out",type:"socks",server:"127.0.0.1",server_port:19160},{tag:"GEOBLOCK-out",type:"socks",server:"127.0.0.1",server_port:19170},{tag:"direct-out",type:"direct"}],route:{final:"direct-out",rules:[{inbound:"tproxy-in",rule_set:"main-anime-community-ruleset",outbound:"main-out"},{inbound:"tproxy-in",rule_set:"GEOBLOCK-geoblock-community-ruleset",outbound:"GEOBLOCK-out"},{inbound:"main-mixed-in",outbound:"main-out"}],rule_set:[{tag:"main-anime-community-ruleset",type:"inline",rules:[{domain_suffix:"example.com"}]},{tag:"GEOBLOCK-geoblock-community-ruleset",type:"inline",rules:[{domain_suffix:"openai.com"}]}]}}' > "$work/runtime.json"
for section in main GEOBLOCK; do
    port=19160; [ "$section" = main ] || port=19170
    jq -n --arg section "$section" --argjson port "$port" '{dns:{servers:[{tag:"dns-server",type:"udp",server:"9.9.9.9"}],final:"dns-server"},inbounds:[{type:"mixed",tag:"section-in",listen:"127.0.0.1",listen_port:$port}],outbounds:[{tag:($section+"-out"),type:"selector",outbounds:["node"]},{tag:"node",type:"trojan",server:"fixture.example",password:"private"}],route:{final:($section+"-out")}}' > "$work/workers/$section/worker.json"
done
db_snapshot_choices() { jq -n '{proxies:{"main-out":{now:"node"},"GEOBLOCK-out":{now:"node"}}}' > "$2"; }
# Only recommend may reuse a prepared, immutable runtime. A changed local
# dataset must produce a different key; candidate configs remain private.
cp "$work/runtime.json" "$work/runtime.original"
printf '{"rules":[{"domain_suffix":"old.example"}]}\n' > "$work/local-rules.json"
jq --arg path "$work/local-rules.json" '.route.rule_set+=[{tag:"local-test",type:"local",format:"source",path:$path}]' "$work/runtime.json" > "$work/updated"
mv "$work/updated" "$work/runtime.json"
mkdir -p "$work/workers/inactive"
jq -n --arg path "$work/local-rules.json" '{inbounds:[{type:"mixed",tag:"section-in",listen:"127.0.0.1",listen_port:19180}],outbounds:[{tag:"inactive-out",type:"direct"}],route:{final:"inactive-out",rule_set:[{tag:"unread",type:"local",format:"binary",path:$path}]}}' > "$work/workers/inactive/worker.json"
db_action=recommend; db_deadline=$(( $(date +%s)+300 ))
cache_before="$(db_fingerprint)"
db_prepare_runtime_cache "$cache_before" || fail 'runtime cache preparation failed'
prepared_hashes="$(sha256sum "$DB_PREPARED_DIR"/*.json)"
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$work/cached-a.json" udp || fail 'first cached clone failed'
db_make_pair_config udp 9.9.9.9 8.8.8.8 "$work/cached-b.json" udp || fail 'second cached clone failed'
jq -e '.route.rule_set|any(.tag=="local-test" and .type=="inline" and .rules[0].domain_suffix=="old.example")' "$work/cached-a.json" >/dev/null || fail 'local rules not inlined'
jq -e '.dns.servers[1].server=="9.9.9.9"' "$work/cached-b.json" >/dev/null || fail 'candidate DNS was cached'
[ "$(find "$DB_PREPARED_DIR" -maxdepth 1 -name '*.json' | wc -l)" = 3 ] || fail 'prepared runtime was not shared between pairs'
[ "$(sha256sum "$DB_PREPARED_DIR"/*.json)" = "$prepared_hashes" ] || fail 'candidate mutated prepared runtime'
( db_work="$work/pair-a"; mkdir -p "$db_work"; DB_DNS_PORT=20000; DB_PROXY_PORT=20001; db_make_pair_config udp 1.1.1.1 8.8.8.8 "$db_work/child.json" udp ) & cache_a=$!
( db_work="$work/pair-b"; mkdir -p "$db_work"; DB_DNS_PORT=20100; DB_PROXY_PORT=20101; db_make_pair_config udp 9.9.9.9 8.8.8.8 "$db_work/child.json" udp ) & cache_b=$!
wait "$cache_a" || fail 'parallel first clone failed'
wait "$cache_b" || fail 'parallel second clone failed'
jq -e '(.inbounds|any(.listen_port==20001)) and .dns.servers[1].server=="1.1.1.1"' "$work/pair-a/child.json" >/dev/null || fail 'first pair output was not private'
jq -e '(.inbounds|any(.listen_port==20101)) and .dns.servers[1].server=="9.9.9.9"' "$work/pair-b/child.json" >/dev/null || fail 'second pair output was not private'
[ "$(sha256sum "$DB_PREPARED_DIR"/*.json)" = "$prepared_hashes" ] || fail 'parallel clone mutated prepared runtime'
missing_key="$(printf '%s' "$work/workers/main/worker.json" | sha256sum | awk '{print $1}')"
rm "$DB_PREPARED_DIR/$missing_key.json"
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$work/cache-miss.json" udp || fail 'cache miss changed clone behavior'
printf '{"rules":[{"domain_suffix":"new.example"}]}\n' > "$work/local-rules.json"
cache_after="$(db_fingerprint)"; [ "$cache_before" != "$cache_after" ] || fail 'local dataset did not change fingerprint'
db_prepare_runtime_cache "$cache_after" || fail 'changed runtime cache preparation failed'
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$work/cached-new.json" udp || fail 'changed cached clone failed'
jq -e '.route.rule_set|any(.tag=="local-test" and .rules[0].domain_suffix=="new.example")' "$work/cached-new.json" >/dev/null || fail 'changed ruleset reused stale cache'
cp "$work/runtime.original" "$work/runtime.json"
DB_PREPARED_DIR=''; db_action=benchmark; db_deadline=0
db_make_pair_config doh cloudflare-dns.com/dns-query 8.8.8.8 "$work/child.json" udp || fail 'section runtime clone rejected'
jq -e '.outbounds[0].server_port!=19160 and .outbounds[1].server_port!=19170 and (.route.rules|all(.inbound!="main-mixed-in"))' "$work/child.json" >/dev/null || fail 'production worker endpoint or mixed-only route retained'
for config in "$work"/section-*.json; do
    jq -e '.dns.servers[1].server=="cloudflare-dns.com" and .outbounds[0].default=="node" and .experimental.clash_api==null and (.inbounds|all(.listen=="127.0.0.1"))' "$config" >/dev/null || fail 'cloned worker did not use candidate DNS/current selection'
done
[ "$(find "$work" -maxdepth 1 -name 'section-*.json' | wc -l)" = 2 ] || fail 'not all sections cloned'
before="$(db_fingerprint)"
jq '.outbounds[1].server="changed.example"' "$work/workers/main/worker.json" > "$work/changed"; mv "$work/changed" "$work/workers/main/worker.json"
after="$(db_fingerprint)"; [ "$before" != "$after" ] || fail 'worker change absent from proof fingerprint'
cp "$work/workers/main/worker.json" "$work/safe-worker"
jq '.outbounds+=[{type:"socks",tag:"unsafe",server:"127.0.0.1",server_port:19170}]' "$work/safe-worker" > "$work/workers/main/worker.json"
if db_make_pair_config udp 1.1.1.1 8.8.8.8 "$work/child.json" udp; then fail 'worker loopback production relay accepted'; fi
[ "$DB_DNS_PORT|$DB_PROXY_PORT" = '19553|19554' ] || fail 'failed worker clone leaked global ports'
cp "$work/safe-worker" "$work/workers/main/worker.json"
db_make_pair_config udp 1.1.1.1 8.8.8.8 "$work/child.json" udp
db_query() { echo 'NOERROR|12'; }
db_transport_guards() { [ "$DB_PROXY_PORT" != 19605 ]; }
repeat=9
if db_section_guards; then fail 'section transport failure accepted'; fi
[ "$repeat" = 9 ] || fail 'section loop overwrote outer confirmation progress counter'
printf '%s' "$db_section_results" | jq -e 'any(.success==false)' >/dev/null || fail 'section failure not reported'
jq '.outbounds+=[{tag:"cfwarp-out",type:"direct"}]|.route.rules+=[{outbound:"main-out",rule_set:"main-user-domains-ruleset"},{outbound:"cfwarp-out",rule_set:"cfwarp-youtube-community-ruleset"}]|.route.rule_set+=[{type:"inline",tag:"main-user-domains-ruleset",rules:[{domain_suffix:[range(0;50)|"custom"+tostring+".example"]}]},{type:"inline",tag:"cfwarp-youtube-community-ruleset",rules:[]}]' "$work/child.json" > "$work/updated"; mv "$work/updated" "$work/child.json"
db_tested_sections='["GEOBLOCK","cfwarp","main"]'
db_query() { echo "$1" >> "$work/query-domains"; echo 'NOERROR|12'; }
db_transport_guards() { if grep -q '^https://googlevideo.com/' "$db_section_endpoints"; then fail 'DNS-only apex used as HTTPS canary'; fi; }
db_section_guards || fail 'representative section probes failed'
[ "$(grep -c '^custom' "$work/query-domains")" -le 6 ] || fail 'custom domain ruleset was exhaustively probed'
db_status | jq -e '.testedSections|index("cfwarp")' >/dev/null || fail 'section progress not published'
(
    db_measurement_profile=minute_sample
    db_sample_cache_dir="$(mktemp -d "$work/sample-cache.XXXXXX")"
    write_community_service_probes() {
        echo "$1" >> "$work/probe-list-builds"
        case "$1" in anime) echo 'community|anime|shikimori.one';; geoblock) echo 'community|geoblock|openai.com';; youtube) echo 'community|youtube|youtube.com';; esac
    }
    : > "$work/probe-list-builds"
    : > "$work/query-domains"
    db_section_guards || fail 'minute sample omitted an active section'
    printf '%s' "$db_section_results" | jq -e 'length==3 and all(.success and .dnsCount==1 and .httpsCount==1 and (.sampledDomains|length)==1 and .fullCompatibilityVerified==false)' >/dev/null || fail 'minute section coverage is not an explicit single-domain sample'
    [ "$(wc -l < "$work/query-domains")" = 3 ] || fail 'minute section sample still exhaustive'
    first_builds="$(wc -l < "$work/probe-list-builds")"; first_rows="$db_section_results"
    db_section_guards || fail 'cached minute sample failed'
    [ "$db_section_results" = "$first_rows" ] || fail 'cached sample changed sections or domains'
    [ "$(wc -l < "$work/query-domains")" = 6 ] || fail 'cached scope skipped fresh DNS measurements'
    [ "$(wc -l < "$work/probe-list-builds")" = "$first_builds" ] || fail 'minute sample rebuilt deterministic section scope on every pair'
    db_measurement_profile=full
    db_section_guards || fail 'manual diagnostics failed with a sample cache present'
    [ "$(wc -l < "$work/probe-list-builds")" -gt "$first_builds" ] || fail 'manual diagnostics reused short sample scope'
)

# Recommendation mode stops only after recording a mandatory failure;
# diagnostic mode retains every section and domain, and advisory is not fatal.
db_transport_guards() { echo attempt >> "$work/section-attempts"; return 1; }
: > "$work/section-attempts"; db_action=recommend
if db_section_guards; then fail 'recommendation accepted failed section'; fi
[ "$(wc -l < "$work/section-attempts")" = 1 ] || fail 'recommendation probed later sections after mandatory failure'
printf '%s' "$db_section_results" | jq -e 'length==1 and .[0].success==false and .[0].error=="section_transport_failed"' >/dev/null || fail 'first failed section evidence lost'
: > "$work/section-attempts"; db_action=pair_test
if db_section_guards; then fail 'diagnostics accepted failed section'; fi
[ "$(wc -l < "$work/section-attempts")" = 3 ] || fail 'diagnostic section coverage shortened'

(
    # Full diagnostics preserve both required logical samples. A timeout may
    # add only one fresh attempt to each sample; all response criteria stay.
    db_measurement_profile=full; db_action=pair_test
    db_deadline=$(( $(date +%s)+300 )); db_probe_deadline=0
    write_compatibility_domains() { printf 'required|fixture|claude.ai\n' > "$1"; : > "$2"; }
    db_child_start() { return 0; }; db_child_stop() { :; }
    db_transport_guards() { db_https_attempted=true; return 0; }; db_section_guards() { return 0; }
    db_query() {
        case "$1" in *.invalid) echo NXDOMAIN; return 0;; esac
        echo attempt >> "$work/full-dns-attempts"
        case "$full_dns_fixture" in
            recovered) if [ "$(wc -l < "$work/full-dns-attempts")" = 1 ]; then echo 'ERROR|TIMEOUT'; return 1; fi;;
            sustained) echo 'ERROR|TIMEOUT'; return 1;;
            refused) echo 'ERROR|REFUSED'; return 1;;
            unusable) echo 'ERROR|UNUSABLE_ANSWER'; return 1;;
            cancelled) : > "$db_cancel_file"; echo 'ERROR|TIMEOUT'; return 1;;
            invalid_retry) if [ "$(wc -l < "$work/full-dns-attempts")" = 1 ]; then echo 'ERROR|TIMEOUT'; else echo 'NOERROR|12'; fi; return 1;;
        esac
        echo 'NOERROR|12'
    }
    : > "$work/full-dns-attempts"; full_dns_fixture=recovered
    db_check_pair dot cloudflare cloudflare-dns.com 77.88.8.8 udp
    printf '%s' "$db_pair_json" | jq -e '.success and .stats.reliable and .stats.totalQueries==2 and .stats.successCount==2 and .stats.retryCount==1 and .stats.recoveredRetries==1 and (.stats.retryDetails|length)==1 and .stats.retryDetails[0].domain=="claude.ai" and .stats.retryDetails[0].initialError=="ERROR|TIMEOUT" and .stats.retryDetails[0].finalResult=="NOERROR|12" and .stats.retryDetails[0].recovered' >/dev/null || fail 'full recovered timeout failed or retry evidence missing'
    [ "$(wc -l < "$work/full-dns-attempts")" = 3 ] || fail 'full logical DNS samples or single timeout retry changed'
    : > "$work/full-dns-attempts"; : > "$db_work/retries.jsonl"; full_dns_fixture=sustained
    if db_sample_query claude.ai > "$work/full-query-output"; then fail 'sustained full timeout accepted'; fi
    [ "$(wc -l < "$work/full-dns-attempts")" = 2 ] || fail 'full sustained timeout did not stop at two attempts'
    jq -s -e 'length==1 and .[0].recovered==false and .[0].finalResult=="ERROR|TIMEOUT"' "$db_work/retries.jsonl" >/dev/null || fail 'sustained full timeout evidence missing'
    : > "$work/full-dns-attempts"
    db_check_pair dot cloudflare cloudflare-dns.com 77.88.8.8 udp
    printf '%s' "$db_pair_json" | jq -e '.success==false and .stats.reliable==false and .stats.retryCount==2 and .stats.recoveredRetries==0 and .httpsTested==false' >/dev/null || fail 'sustained full DNS timeout granted compatibility'
    for full_dns_fixture in refused unusable invalid_retry; do
        : > "$work/full-dns-attempts"; : > "$db_work/retries.jsonl"
        if db_sample_query claude.ai > "$work/full-query-output"; then fail 'invalid full DNS reply accepted'; fi
        attempts=1; [ "$full_dns_fixture" != invalid_retry ] || attempts=2
        [ "$(wc -l < "$work/full-dns-attempts")" = "$attempts" ] || fail 'non-timeout full DNS reply retried'
        if [ "$full_dns_fixture" = invalid_retry ]; then
            grep -q '^ERROR|' "$work/full-query-output" || fail 'failed retry returned a success-looking result'
            jq -s -e 'length==1 and .[0].recovered==false' "$db_work/retries.jsonl" >/dev/null || fail 'failed retry marked recovered'
        else [ ! -s "$db_work/retries.jsonl" ] || fail 'non-timeout fabricated retry evidence'; fi
    done
    for constraint in pair_budget worker_budget cancelled runtime; do
        : > "$work/full-dns-attempts"; : > "$db_work/retries.jsonl"; full_dns_fixture=sustained
        db_deadline=$(( $(date +%s)+300 )); db_probe_deadline=0
        case "$constraint" in
            pair_budget) db_probe_deadline=$(( $(date +%s)+1 ));;
            worker_budget) db_deadline=$(( $(date +%s)+1 ));;
            cancelled) full_dns_fixture=cancelled;;
            runtime) db_runtime_safe() { db_child_error=memory_pressure; return 1; };;
        esac
        if db_sample_query claude.ai > "$work/full-query-output"; then fail 'guarded full timeout accepted'; fi
        [ "$(wc -l < "$work/full-dns-attempts")" = 1 ] || fail 'full retry ignored budget/cancellation/runtime guard'
        [ ! -s "$db_work/retries.jsonl" ] || fail 'unattempted full retry fabricated evidence'
        rm -f "$db_cancel_file"
    done
)

write_compatibility_domains() {
    printf '%s\n' 'advisory|fixture|advisory.example' 'required|fixture|blocked.example' 'required|fixture|later.example' > "$1"; : > "$2"
}
db_query() {
    echo "$1" >> "$work/domain-attempts"
    case "$1" in advisory.example|blocked.example) echo 'ERROR|TIMEOUT'; return 1;; *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|12';; esac
}
: > "$work/domain-attempts"; db_action=recommend
db_measure | jq -e '.reliable==false and .error=="dns_query_failed" and .totalQueries==4 and (.failedQueries|length)==4' >/dev/null || fail 'required failure evidence missing'
[ "$(wc -l < "$work/domain-attempts")" = 8 ] || fail 'recommendation did not finish both logical samples with one timeout retry then stop before later domains'
: > "$work/domain-attempts"; db_action=pair_test
db_measure | jq -e '.reliable==false and .error=="dns_query_failed" and .totalQueries==6 and .nxdomainOk' >/dev/null || fail 'diagnostic DNS coverage shortened'
[ "$(wc -l < "$work/domain-attempts")" = 11 ] || fail 'diagnostic logical samples, single timeout retries or NXDOMAIN check omitted'
(
    db_measurement_profile=minute_sample; db_action=recommend
    db_sample_cache_dir="$(mktemp -d "$work/base-sample-cache.XXXXXX")"
    write_compatibility_domains() {
        echo build >> "$work/base-list-builds"
        printf '%s\n' 'base|google_play|play.googleapis.com' 'base|google_play|android.clients.google.com' 'base|chatgpt|chatgpt.com' 'base|chatgpt|api.openai.com' 'community|fixture|later.example' > "$1"; : > "$2"
    }
    db_query() { echo "$1" >> "$work/sample-domains"; case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|12';; esac; }
    : > "$work/sample-domains"
    : > "$work/base-list-builds"
    db_measure | jq -e '.reliable and .totalQueries==2 and .nxdomainOk and .measurementProfile=="minute_sample" and .fullCompatibilityVerified==false and .sampledDomains==["play.googleapis.com","chatgpt.com"]' >/dev/null || fail 'minute base DNS sample contract missing'
    [ "$(wc -l < "$work/sample-domains")" = 3 ] || fail 'minute DNS sample still repeats/exhausts full list'
    db_measure | jq -e '.reliable and .totalQueries==2 and .nxdomainOk and .sampledDomains==["play.googleapis.com","chatgpt.com"]' >/dev/null || fail 'cached base sample changed coverage'
    [ "$(wc -l < "$work/sample-domains")" = 6 ] || fail 'cached base scope skipped fresh DNS/NXDOMAIN queries'
    [ "$(wc -l < "$work/base-list-builds")" = 1 ] || fail 'minute sample rebuilt deterministic base scope on every pair'
    db_deadline=$(( $(date +%s)+300 )); db_probe_deadline=0
    : > "$work/retries.jsonl"; : > "$work/retry-dns-attempts"
    db_query() {
        echo "$1" >> "$work/retry-dns-attempts"
        if [ "$(wc -l < "$work/retry-dns-attempts")" = 1 ]; then echo 'ERROR|TIMEOUT'; return 1; fi
        case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|12';; esac
    }
    db_measure | jq -e '.reliable and .nxdomainOk' >/dev/null || fail 'minute transient DNS timeout was not retried'
    [ "$(wc -l < "$work/retry-dns-attempts")" = 4 ] || fail 'transient DNS timeout did not get exactly one retry'
    jq -s -e 'length==1 and .[0].kind=="dns" and .[0].initialError=="ERROR|TIMEOUT" and .[0].recovered' "$work/retries.jsonl" >/dev/null || fail 'recovered DNS timeout hidden'
    db_query() { echo attempt >> "$work/retry-dns-attempts"; echo 'ERROR|REFUSED'; return 1; }
    : > "$work/retry-dns-attempts"
    db_measure | jq -e '.reliable==false' >/dev/null || fail 'DNS refusal accepted'
    [ "$(wc -l < "$work/retry-dns-attempts")" = 1 ] || fail 'DNS refusal incorrectly retried'
)

(
    # Re-load only the actual transport function, retaining isolated fixtures.
    eval "$(sed -n '/^db_transport_guards()/,/^}/p' "$repo/openwrt/podkop-dns-benchmark")"
    db_bounded_command() { "$@"; }
    curl() {
        count="$(wc -l < "$work/curl-attempts")"; echo attempt >> "$work/curl-attempts"
        output_file=''; previous=''
        for argument in "$@"; do [ "$previous" != -o ] || output_file="$argument"; previous="$argument"; done
        printf '%128s' x > "$output_file"
        case "$curl_fixture" in
            failed) echo '000|0.1'; return 28;;
            transient) if [ "$count" = 0 ]; then echo '000|0.1'; return 28; fi;;
            status) echo '451|0.1'; return 0;;
            tls) echo '000|0.1'; return 35;;
            cert) echo '000|0.1'; return 60;;
            connect|empty|receive)
                if [ "$count" = 0 ]; then
                    echo '000|0.1'
                    case "$curl_fixture" in connect) return 7;; empty) return 52;; receive) return 56;; esac
                fi;;
        esac
        echo '200|0.1'
    }
    printf 'https://fixture.example/|200|required\n' > "$work/fixture-endpoints"
    db_section_endpoints="$work/fixture-endpoints"; db_action=recommend; db_deadline=$(( $(date +%s)+300 ))
    : > "$work/curl-attempts"; curl_fixture=transient
    db_transport_guards || fail 'single transient curl error discarded recommendation'
    [ "$(wc -l < "$work/curl-attempts")" = 2 ] || fail 'transient transport failure was not retried exactly once'
    : > "$work/curl-attempts"; curl_fixture=failed
    if db_transport_guards; then fail 'two failed transport attempts accepted'; fi
    [ "$(wc -l < "$work/curl-attempts")" = 2 ] || fail 'transport retries exceeded two attempts'
    jq -e '.reason=="curl_failed" and .httpStatus=="000"' "$DB_DIR/transport-error.json" >/dev/null || fail 'transport failure evidence lost'
    : > "$work/curl-attempts"; curl_fixture=status
    if db_transport_guards; then fail 'wrong HTTP status accepted'; fi
    [ "$(wc -l < "$work/curl-attempts")" = 1 ] || fail 'wrong HTTP status incorrectly retried'
    : > "$work/curl-attempts"; curl_fixture=transient; db_action=pair_test
    if db_transport_guards; then fail 'diagnostics unexpectedly retried transient transport failure'; fi
    [ "$(wc -l < "$work/curl-attempts")" = 1 ] || fail 'diagnostic transport changed'
    db_measurement_profile=minute_sample; db_action=recommend
    : > "$work/retries.jsonl"; : > "$work/curl-attempts"; curl_fixture=transient
    db_transport_guards || fail 'minute transient HTTP timeout not retried'
    [ "$(wc -l < "$work/curl-attempts")" = 2 ] || fail 'minute HTTP retries exceeded one extra attempt'
    jq -s -e 'length==1 and .[0].kind=="https" and .[0].curlExit==28 and .[0].recovered' "$work/retries.jsonl" >/dev/null || fail 'recovered HTTP timeout hidden'
    for curl_fixture in connect empty receive; do
        : > "$work/curl-attempts"
        db_transport_guards || fail 'eligible transient connection failure not retried'
        [ "$(wc -l < "$work/curl-attempts")" = 2 ] || fail 'connection retry count incorrect'
    done
    for curl_fixture in tls cert status; do
        : > "$work/curl-attempts"
        if db_transport_guards; then fail 'TLS/certificate/wrong HTTP response accepted'; fi
        [ "$(wc -l < "$work/curl-attempts")" = 1 ] || fail 'TLS/certificate/wrong HTTP response retried'
    done
    jq -e '.curlExit==0 and .elapsedSeconds==0.1 and .httpStatus=="451"' "$DB_DIR/transport-error.json" >/dev/null || fail 'HTTP failure timing/exit context missing'
    : > "$work/curl-attempts"; curl_fixture=failed
    if db_transport_guards; then fail 'two HTTP timeouts accepted'; fi
    [ "$(wc -l < "$work/curl-attempts")" = 2 ] || fail 'two minute timeouts exceeded retry bound'
    jq -e '.curlExit==28 and .elapsedSeconds==0.1' "$DB_DIR/transport-error.json" >/dev/null || fail 'timeout exit code omitted'
    # This unit boundary has mocked transport. Freeze its clock so scheduler
    # delay cannot turn the intended one-second budget into zero attempts.
    date() { if [ "$*" = +%s ]; then echo 1000; else command date "$@"; fi; }
    db_probe_deadline=1000
    : > "$work/curl-attempts"
    if db_transport_guards; then fail 'expired pair budget accepted'; fi
    [ "$(wc -l < "$work/curl-attempts")" = 0 ] || fail 'transport started after pair deadline'
    db_probe_deadline=1001
    : > "$work/curl-attempts"
    if db_transport_guards; then fail 'deadline-constrained timeout accepted'; fi
    [ "$(wc -l < "$work/curl-attempts")" = 1 ] || fail 'retry started without sufficient remaining pair budget'
)

(
    db_measurement_profile=minute_sample; db_action=recommend
    db_child_start() { db_child_error=child_start_failed; return 1; }
    db_child_stop() { :; }; db_runtime_safe() { return 0; }
    db_check_pair doh cloudflare cloudflare-dns.com 8.8.8.8 udp
    printf '%s' "$db_pair_json" | jq -e '.success==false and .stats==null and .error=="child_start_failed" and .httpsTested==false' >/dev/null || fail 'unmeasured child failure fabricated DNS/HTTPS measurements'
    db_child_start() { return 0; }
    db_measure() { echo '{"reliable":false,"error":"dns_query_failed","averageMs":null}'; }
    db_transport_guards() { fail 'HTTPS ran after DNS-stage failure'; }
    db_check_pair doh cloudflare cloudflare-dns.com 8.8.8.8 udp
    printf '%s' "$db_pair_json" | jq -e '.success==false and .error=="dns_query_failed" and .httpsTested==false' >/dev/null || fail 'DNS-stage failure claimed HTTPS coverage'
)
# Queue must not stop at the previous 24-pair cap; no proof is granted.
db_fingerprint() { echo stable; }; db_busy() { return 1; }
db_validate_pair() { :; }
db_check_pair() {
    if [ "$db_phase" = recheck ]; then jq -e '.phase=="recheck" and .state=="running"' "$DB_STATUS" >/dev/null || fail 'recheck phase published only after lengthy first run'; fi
    db_pair_json="$(db_pair_object "$1" "$2" "$3" "$4" true "$5" | jq '.stats={reliable:true,averageMs:7}|.sectionResults=[]')"
}
db_results="$(jq -cn '[range(0;5)|{protocol:"udp",id:("c"+tostring),dnsServer:"1.1.1.1",reliable:true,primaryEligible:true}]')"
db_bootstrap_results="$(jq -cn '[range(0;5)|{server:"8.8.8.8",reliable:true}]')"
db_action=pairs; db_individual_complete=true; db_deadline=$(( $(date +%s)+300 ))
db_pairs || fail 'full 25-pair queue rejected'
db_status | jq -e '.total==25 and (.pairResults|length)==25' >/dev/null
# Automatic selection has its own process-isolation fixture: all selected
# combinations, late winner, top-two repeats and no result on cancellation.
sh "$repo/tests/test_pe_dns_parallel.sh"
# Native external-command bounds and contextual fingerprint discriminants.
db_action=recommend; db_deadline=$(( $(date +%s)+300 ))
db_fingerprint() { echo changed; }
if db_fast_context expected 2> "$work/context-error"; then fail 'changed fingerprint accepted'; fi
grep -q 'dns_fast_context reason=fingerprint_changed expected=expected current=changed' "$work/context-error" || fail 'context discriminant absent'
db_deadline=$(( $(date +%s)+1 ))
if db_bounded_command sleep 5; then fail 'blocking external command exceeded recommendation budget'; fi
echo 'PASS: cloned isolation, sampled scope, diagnostics and all-selected comparison'
