#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export PODKOP_DNS_BENCHMARK_WORKERS_DIR="$work/workers"
export PODKOP_MUTATION_LOCK_DIR="$work/mutation" PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/legacy"
export PODKOP_DNS_BENCHMARK_BIN="$work/engine"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare
uci() { case "$*" in 'export podkop') echo 'config settings';; *config_path) echo "$work/runtime.json";; *) return 1;; esac; }
printf '{"outbounds":[],"route":{}}\n' > "$work/runtime.json"
printf '%s\n' '#!/bin/sh' '[ "$1" = version ] || exit 1' \
    'read -r score < /proc/self/oom_score_adj; [ "$score" = 1000 ] || exit 1' \
    '[ ! -f "$0.failed" ] || { printf "sing-box version misleading\\n"; exit 1; }' \
    '[ ! -f "$0.hung" ] || exec sleep 30' 'cat "$0.version"' > "$work/engine"
chmod 700 "$work/engine"
cp "$work/engine" "$work/engine.original"
printf 'sing-box version 1.13.21\n\nEnvironment: go1.25 linux/arm64\nTags: with_utls,with_clash_api\nRevision: fixture-a\n' > "$work/engine.version"
cp "$work/engine.version" "$work/version.original"
baseline="$(db_fingerprint)" || fail 'unchanged Engine identity unavailable'
[ -n "$baseline" ] && [ "$baseline" = "$(db_fingerprint)" ] || fail 'unchanged Engine fingerprint is not stable'
printf '# updated Engine bytes\n' >> "$work/engine"
[ "$baseline" != "$(db_fingerprint)" ] || fail 'same-path same-version Engine replacement did not invalidate fingerprint'
cp "$work/engine.original" "$work/engine"
[ "$baseline" = "$(db_fingerprint)" ] || fail 'restored Engine fingerprint differs'
printf 'Revision: fixture-b\n' >> "$work/engine.version"
[ "$baseline" != "$(db_fingerprint)" ] || fail 'full version identity change without executable change ignored'
cp "$work/version.original" "$work/engine.version"
[ "$baseline" = "$(db_fingerprint)" ] || fail 'restored full version identity differs'
# Even trailing output bytes belong to the complete identity.
printf '\n' >> "$work/engine.version"
[ "$baseline" != "$(db_fingerprint)" ] || fail 'trailing version output bytes ignored'
cp "$work/version.original" "$work/engine.version"

primary_pair='{"success":true,"protocol":"udp","id":"cloudflare","dnsServer":"1.1.1.1","bootstrapDnsServer":"8.8.8.8","bootstrapProtocol":"udp"}'
reserve_pair='{"success":true,"protocol":"udp","id":"controld_unfiltered","dnsServer":"76.76.2.0","bootstrapDnsServer":"8.8.8.8","bootstrapProtocol":"udp","measurementProfile":"full","stats":{"reliable":true},"rechecked":true,"automaticEligible":true,"mainFamily":"controld","bootstrapFamily":"google","bootstrapTest":{"success":true,"protocol":"udp","server":"8.8.8.8"}}'
arm_primary() {
    db_report_id=engine-primary
    jq -cn --argjson pair "$primary_pair" --arg reportId "$db_report_id" '{reportId:$reportId,state:"done",action:"pair_test",pairResult:$pair}' > "$DB_REPORT"
    db_write_proof "$primary_pair" || fail 'primary proof not written'
    db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 udp || fail 'unchanged Engine primary proof rejected'
}
arm_reserve() {
    db_report_id=engine-reserve; db_pair_json="$reserve_pair"
    jq -cn --argjson pair "$reserve_pair" --arg reportId "$db_report_id" '{reportId:$reportId,state:"done",action:"recommend_reserve",reserve:true,selectionComplete:true,fullVerificationComplete:true,measurementProfile:"full",pairResult:$pair,recommendation:$pair,fullVerificationResults:[$pair],recommendationBootstrapTest:$pair.bootstrapTest,currentPrimaryProvider:"cloudflare",currentBootstrapProvider:"cloudflare"}' > "$DB_REPORT"
    db_write_reserve_proof "$(db_fingerprint)" || fail 'reserve proof not written'
    db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp || fail 'unchanged Engine reserve proof rejected'
}
mutate_engine() {
    case "$1" in
      bytes) printf '# new release\n' >> "$work/engine";;
      version) printf 'sing-box version 1.13.22\nEnvironment: go1.25 linux/arm64\n' > "$work/engine.version";;
    esac
}
restore_engine() { cp "$work/engine.original" "$work/engine"; cp "$work/version.original" "$work/engine.version"; }
for mutation in bytes version; do
    arm_primary; mutate_engine "$mutation"
    if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 udp; then fail "$mutation change retained apply proof"; fi
    if db_start apply udp cloudflare 1.1.1.1 8.8.8.8 udp > "$work/admission.json"; then fail "$mutation change admitted apply"; fi
    jq -e '.success==false and .error=="stale_proof"' "$work/admission.json" >/dev/null || fail 'apply identity refusal omitted stale_proof'
    restore_engine
    arm_reserve; mutate_engine "$mutation"
    if db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail "$mutation change retained reserve proof"; fi
    if db_start reserve_save udp controld_unfiltered 76.76.2.0 8.8.8.8 udp > "$work/admission.json"; then fail "$mutation change admitted reserve save"; fi
    jq -e '.success==false and .error=="stale_reserve_proof"' "$work/admission.json" >/dev/null || fail 'reserve identity refusal omitted stale_reserve_proof'
    restore_engine
done
arm_primary; cp "$DB_REPORT" "$work/primary-report.json"
arm_reserve; cp "$DB_REPORT" "$work/reserve-report.json"
for invalid in missing non_executable unreadable failed empty whitespace hung hash_failed invalid_hash low_memory; do
    (
        case "$invalid" in
          missing) rm "$work/engine";;
          non_executable) chmod 600 "$work/engine";;
          unreadable) chmod 100 "$work/engine";;
          failed) : > "$work/engine.failed";;
          empty) : > "$work/engine.version";;
          whitespace) printf ' \n\n' > "$work/engine.version";;
          hung) : > "$work/engine.hung"; db_probe_deadline=$(( $(date +%s)+1 ));;
          hash_failed) sha256sum() { return 1; };;
          invalid_hash) sha256sum() { echo invalid; };;
          low_memory) printf 'MemAvailable: 65536 kB\n' > "$work/low-memory"; PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$work/low-memory";;
        esac
        if fingerprint="$(db_fingerprint 2>/dev/null)"; then fail "$invalid identity accepted"; fi
        [ -z "$fingerprint" ] || fail "$invalid identity returned a usable fingerprint"
        cp "$work/primary-report.json" "$DB_REPORT"
        if db_proof_valid udp cloudflare 1.1.1.1 8.8.8.8 udp; then fail "$invalid identity retained apply proof"; fi
        cp "$work/reserve-report.json" "$DB_REPORT"
        if db_reserve_proof_valid udp controld_unfiltered 76.76.2.0 8.8.8.8 udp; then fail "$invalid identity retained reserve proof"; fi
        if db_write_proof "$primary_pair"; then fail "$invalid identity minted proof"; fi
    )
    chmod 700 "$work/engine" 2>/dev/null || true
    restore_engine; rm -f "$work/engine.failed" "$work/engine.hung"
done
[ ! -e "$DB_LOCK" ] && [ ! -e "$PODKOP_MUTATION_LOCK_DIR" ] || fail 'stale identity launched a mutation worker'
echo 'PASS: exact executable hash and complete Engine identity bind primary/reserve proofs; unreadable, failed, empty and bounded identities fail closed'
