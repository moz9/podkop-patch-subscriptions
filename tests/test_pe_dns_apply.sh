#!/bin/sh
# Bash supplies BASHPID for the owned-process signal fixture. The production
# helper remains POSIX/BusyBox ash; test runner may invoke this file via sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
jq_binary_mode=0
if command -v cygpath >/dev/null 2>&1; then
    tmp="$(cygpath -m "$tmp")"
    jq_binary_mode=1
fi
# Router jq omits ONIGURUMA. Exercise every scenario with regex unavailable.
jq() {
    local argument
    for argument in "$@"; do
        case "$argument" in *'test('*|*'match('*|*'sub('*|*'gsub('*)
            printf 'fixture: jq regex functions unavailable without ONIGURUMA\n' >&2; return 1;;
        esac
    done
    if [ "$jq_binary_mode" = 1 ]; then command jq -b "$@"; else command jq "$@"; fi
}
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$repo/openwrt/podkop-dns-apply" ] || fail 'DNS-only transaction helper missing'
PODKOP_DNS_APPLY_LIBRARY_ONLY=1
. "$repo/openwrt/podkop-dns-apply"
eval "$(declare -f dns_apply_hash | sed '1s/dns_apply_hash/dns_apply_hash_production/')"
# Exercise the actual legacy loader under strict inherited benchmark options.
printf '%s\n' '[ -z "$IPKG_INSTROOT" ] || true' 'false' ':' > "$tmp/legacy-core.sh"
printf ':\n' > "$tmp/legacy-optimizer.sh"
(
    PODKOP_DNS_APPLY_CORE="$tmp/legacy-core.sh"
    PODKOP_DNS_APPLY_OPTIMIZER="$tmp/legacy-optimizer.sh"
    podkop_section_context_hash() { :; }
    dns_apply_run() { dns_apply_reply; }
    dns_apply_main prepare dot cloudflare-dns.com udp 77.88.8.1
) > "$tmp/legacy-loader.json" || fail 'strict benchmark options killed legacy library loader'
jq -e '.success==true' "$tmp/legacy-loader.json" >/dev/null || fail 'legacy loader omitted structured result'

printf '%s\n' '{"dns":{"servers":[{"tag":"bootstrap-dns-server","type":"udp","server":"1.1.1.1"},{"tag":"dns-server","type":"https","server":"old.example","path":"/dns-query","detour":"direct-out"},{"tag":"fakeip","type":"fakeip","inet4_range":"198.18.0.0/15"}],"rules":[{"server":"fakeip"}],"final":"dns-server"},"outbounds":[{"tag":"main-out","type":"selector","outbounds":["main-urltest-out"]},{"tag":"main-urltest-out","type":"urltest","outbounds":["node-a"]},{"tag":"node-a","type":"vless","server":"private.invalid"}],"route":{"default_domain_resolver":"dns-server","rules":[]}}' > "$tmp/source.json"
printf '%s\n' '[{"tag":"dns-server","type":"tls","server":"9.9.9.9","server_port":853},{"tag":"bootstrap-dns-server","type":"tcp","server":"8.8.8.8","server_port":53}]' > "$tmp/pair.json"
dns_apply_patch_json "$tmp/source.json" "$tmp/pair.json" "$tmp/new.json" || fail patch
jq -e '.dns.servers[1].type=="tls" and .dns.servers[1].server=="9.9.9.9" and .dns.servers[1].detour=="direct-out" and (.dns.servers[1]|has("path")|not)' "$tmp/new.json" >/dev/null || fail 'wrong upstream patch'
jq -S 'del(.dns.servers[0],.dns.servers[1])' "$tmp/source.json" > "$tmp/a"
jq -S 'del(.dns.servers[0],.dns.servers[1])' "$tmp/new.json" > "$tmp/b"
cmp "$tmp/a" "$tmp/b" || fail 'pools routes fakeip changed'
jq '.dns.servers += [.dns.servers[0]]' "$tmp/source.json" > "$tmp/duplicate.json"
! dns_apply_patch_json "$tmp/duplicate.json" "$tmp/pair.json" "$tmp/bad.json" 2>/dev/null || fail 'duplicate upstream accepted'
echo 'PASS: DNS-only exact patch and unsupported-layout refusal'
jq '.experimental.clash_api.external_controller="127.0.0.1:9090"' "$tmp/source.json" > "$tmp/controller.json"
[ "$(dns_apply_controller "$tmp/controller.json")" = 127.0.0.1:9090 ] || fail 'local controller normalization'
jq '.experimental.clash_api.external_controller="evil.example:9090"' "$tmp/source.json" > "$tmp/remote-controller.json"
! dns_apply_controller "$tmp/remote-controller.json" || fail 'remote controller accepted'

# Integration fixtures keep the real transaction and snapshot logic. Only
# OpenWrt's UCI/service/process boundaries are replaced on the Windows host.
. "$repo/openwrt/podkop-service-snapshot.sh"
PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
. "$repo/openwrt/podkop-dns-optimizer"
dns_apply_load() { :; }
dns_apply_hash() {
    if [ "$1" = "$fixture/runtime.json" ] && jq -e '.version==3 and .mode=="single"' "$fixture/root/metadata.json" >/dev/null; then
        sha256sum "$1" "$fixture/root/logical.json" "$fixture/root/metadata.json" | sha256sum | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}
sing-box() { [ ! -f "$fixture/invalid" ]; }
uci() {
    [ "$1" != -q ] || shift
    local action="$1" key value source
    shift; source="$PODKOP_DNS_APPLY_UCI_FILE"
    [ ! -f "$fixture/staged" ] || source="$fixture/staged"
    case "$action" in
      set|commit|revert) printf '%s\n' "$action" >> "$fixture/uci-mutations";;
    esac
    case "$action" in
      get) key="$1"; case "$key" in /proc/self/fd/3.*) key="podkop.${key#/proc/self/fd/3.}"; source=/proc/self/fd/3;; esac
        fixture_uci_get "$key" "$source" || { [ "$source" = "$fixture/staged" ] && fixture_uci_get "$key" "$PODKOP_DNS_APPLY_UCI_FILE"; };;
      show|export) if [ "${1:-}" = /proc/self/fd/3 ]; then cat <&3; else cat "$source"; fi;;
      changes) if [ -f "$fixture/draft-only" ]; then cat "$fixture/draft-only"; else [ ! -f "$fixture/staged" ] || cat "$fixture/staged"; fi;;
      set) key="${1%%=*}"; value="${1#*=}"; awk -F= -v key="$key" '$1!=key' "$source" > "$fixture/stage.new"; printf '%s=%s\n' "$key" "$value" >> "$fixture/stage.new"; mv "$fixture/stage.new" "$fixture/staged";;
      revert) rm -f "$fixture/staged";;
      commit) if [ -f "$fixture/commit-fail" ]; then rm "$fixture/commit-fail"; return 1; fi; cp "$fixture/staged" "$PODKOP_DNS_APPLY_UCI_FILE"; rm "$fixture/staged";;
      *) return 1;;
    esac
}
# Parse the real committed UCI syntax used by the atomic DNS writer. Saved-mode
# fixtures retain their existing flat model because they must never write UCI.
fixture_uci_get() {
    awk -F= -v key="$1" '
      function clean(s) { gsub(/["\047]/,"",s); return s }
      $1==key { sub(/^[^=]*=/,""); print; found=1; exit }
      { n=split($0,a,/[ \t]+/); first=1; if(a[first]=="")first++
        if(a[first]=="config") section=clean(a[first+2])
        if(a[first]=="option" && "podkop." section "." clean(a[first+1])==key) {
          line=$0; sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]+/,"",line)
          print clean(line); found=1; exit
        }
      }
      END { exit !found }
    ' "$2"
}
eval "$(declare -f dns_apply_atomic | sed '1s/dns_apply_atomic/dns_apply_atomic_fixture_original/')"
dns_apply_atomic() {
    if [ "$2" = "$PODKOP_DNS_APPLY_UCI_FILE" ] && [ -f "$fixture/uci-write-fail" ]; then
        rm "$fixture/uci-write-fail"; return 1
    fi
    local fixture_rc=0
    dns_apply_atomic_fixture_original "$@" || fixture_rc=$?
    if [ "$fixture_rc" = 0 ] && [ "$2" = "$PODKOP_DNS_APPLY_UCI_FILE" ] && [ -s "$fixture/draft-on-write" ]; then
        cp "$fixture/draft-on-write" "$fixture/staged"; rm "$fixture/draft-on-write"
    fi
    return "$fixture_rc"
}
config_load() { :; }
config_get() { eval "$1=\"\$fixture/runtime.json\""; }
config_foreach() { "$1" main; }
validate_subscription_urltest_section() { return 0; }
subscription_required_services_json() { printf '["gemini"]\n'; }
get_subscription_cache_path() { printf '%s/active\n' "$fixture"; }
get_subscription_all_cache_path() { printf '%s/all\n' "$fixture"; }
get_subscription_items_cache_path() { printf '%s/items\n' "$fixture"; }
get_subscription_link_id() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
subscription_services_cache_path() { printf '%s/services\n' "$fixture"; }
subscription_services_context() { { jq -cS '.dns' "$fixture/runtime.json"; cat "$PODKOP_DNS_APPLY_UCI_FILE"; } | sha256sum | awk '{print $1}'; }
subscription_services_preflight() { return 0; }
subscription_services_policy() { cat "$fixture/services"; }
subscription_sing_box_reload_ready() { return 0; }
podkop_section_context_hash() { sha256sum "$PODKOP_DNS_APPLY_UCI_FILE" | awk '{print $1}'; }
dns_catalog_endpoint() { local value="$2"; [ "$value" != alias.example ] || value=9.9.9.9; jq -cn --arg value "$value" --arg protocol "$1" '{host:$value,port:({udp:53,tcp:53,doh:443,dot:853}[$protocol]),path:"/dns-query"}'; }
dns_apply_process_identity() { printf '%s\n' "${fixture_identity:-fixture-process:1}"; }
dns_apply_reload() {
    printf 'reload\n' >> "$fixture/reloads"
    if [ -s "$fixture/draft-on-reload" ]; then
        cp "$fixture/draft-on-reload" "$fixture/staged"; rm "$fixture/draft-on-reload"
    fi
    if [ -f "$fixture/foreign-on-reload" ]; then
        rm "$fixture/foreign-on-reload"
        printf '# foreign saved edit\n' >> "$PODKOP_DNS_APPLY_UCI_FILE"
        return 0
    fi
    if [ -f "$fixture/edit-uci-on-reload" ]; then
        rm "$fixture/edit-uci-on-reload"
        printf 'podkop.settings.concurrent=preserve\n' >> "$PODKOP_DNS_APPLY_UCI_FILE"
    fi
    if [ -f "$fixture/signal" ]; then rm "$fixture/signal"; kill -HUP "${BASHPID:-$$}"; fi
    if [ -f "$fixture/reload-fail" ]; then rm "$fixture/reload-fail"; return 1; fi
    [ ! -f "$fixture/rollback-fail" ]
}
dns_apply_live_ready() { [ ! -f "$fixture/live-fail" ]; }
dns_apply_choices() { [ "$1" != capture ] || printf '{"proxies":{}}\n' > "$3"; }
make_fixture() {
    fixture="$tmp/$1"; mkdir -p "$fixture/root/workers/main" "$fixture/rules"
    PODKOP_SECTION_ROOT="$fixture/root"; PODKOP_DNS_APPLY_UCI_FILE="$fixture/uci"
    PODKOP_SERVICE_SNAPSHOT_DIR="$fixture/snapshot"; TMP_RULESET_FOLDER="$fixture/rules"
    PODKOP_DNS_APPLY_BACKUP_DIR="$fixture/backup"
    PODKOP_MUTATION_LOCK_DIR="$fixture/lock"; PODKOP_MUTATION_LEGACY_LOCK_FILE="$fixture/legacy-lock"
    case "$1" in saved-*)
    printf 'podkop.settings.config_path=%s/runtime.json\npodkop.settings.dns_type=doh\npodkop.settings.dns_server=old.example\npodkop.settings.bootstrap_dns_type=udp\npodkop.settings.bootstrap_dns_server=1.1.1.1\n' "$fixture" > "$fixture/uci"
    ;;
    *)
    printf "config settings 'settings'\n option config_path '%s/runtime.json'\n option dns_type 'doh'\n option dns_server 'old.example'\n option bootstrap_dns_type 'udp'\n option bootstrap_dns_server '1.1.1.1'\n" "$fixture" > "$fixture/uci"
    ;;
    esac
    cp "$tmp/source.json" "$fixture/runtime.json"
    cp "$tmp/source.json" "$fixture/root/logical.json"
    cp "$tmp/source.json" "$fixture/root/frontend.json"
    cp "$tmp/source.json" "$fixture/root/workers/main/worker.json"
    printf '{"version":2,"sections":[{"section":"main","port":19160,"api_port":19163}]}\n' > "$fixture/root/metadata.json"
    podkop_section_context_hash > "$fixture/root/context.sha256"
    printf 'secret-vless-link\n' > "$fixture/active"; cp "$fixture/active" "$fixture/all"
    printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":true}]\n' > "$fixture/items"
    printf '{"required":["gemini"],"results":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","checkedAt":1,"expiresAt":2,"services":{"gemini":{"state":"pass"}}}]}\n' > "$fixture/services"
    subscription_services_snapshot_save || fail 'fixture snapshot creation'
    cp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot"
    cp "$fixture/uci" "$fixture/original-uci"
    cp "$fixture/services" "$fixture/original-services"
}
assert_restored() {
    cmp "$fixture/runtime.json" "$tmp/source.json" || fail 'runtime not restored'
    cmp "$fixture/uci" "$fixture/original-uci" || fail 'UCI not restored'
    cmp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot" || fail 'snapshot not restored'
    cmp "$fixture/services" "$fixture/original-services" || fail 'service observations altered'
    [ ! -f "$fixture/staged" ] || fail 'staged changes leaked'
}
if [ "${DNS_APPLY_TEST_SAVED_ONLY:-0}" != 1 ]; then
make_fixture unrelated-draft
podkop_section_names() { echo '["main"]'; }
printf "podkop.main.subscription_selected_link_ids='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\n" > "$fixture/draft-only"
cp "$fixture/draft-only" "$fixture/draft.expected"
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'unrelated draft blocked DNS transaction'
cmp "$fixture/draft-only" "$fixture/draft.expected" || fail 'DNS transaction changed draft'
jq -e '.success==true' "$fixture/result" >/dev/null || fail 'draft transaction did not succeed'
cmp "$fixture/services" "$fixture/original-services" || fail 'draft transaction changed diagnostic observations'
dns_apply_main rollback > "$fixture/result" || fail 'draft transaction rollback failed'
cmp "$fixture/draft-only" "$fixture/draft.expected" || fail 'rollback changed unrelated draft'
cmp "$fixture/uci" "$fixture/original-uci" || fail 'rollback failed to restore committed DNS'
echo 'PASS: initial unrelated draft survives full DNS apply and rollback'

make_fixture dual-pair
dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail 'dual-pair full apply'
grep -q "option secondary_dns_server '1.1.1.1'" "$fixture/uci" || fail 'dual-pair reserve not persisted'
dns_apply_main rollback > "$fixture/result" || fail 'dual-pair full rollback'
assert_restored
echo 'PASS: full dual-pair transaction and exact shared rollback'
make_fixture prepare
dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'prepare failed'
assert_restored
[ ! -e "$fixture/reloads" ] && [ ! -e "$fixture/backup" ] || fail 'dry-run mutated persistent/service state'
echo 'PASS: prepare no mutation/reload'

for draft_point in write reload; do
    make_fixture "late-draft-$draft_point"
    printf "podkop.settings.dns_server='later-user-draft'\n" > "$fixture/draft-on-$draft_point"
    cp "$fixture/draft-on-$draft_point" "$fixture/draft-expected"
    ! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail "late $draft_point draft accepted"
    jq -e '.success==false' "$fixture/result" >/dev/null || fail 'late draft reported success'
    cmp "$fixture/runtime.json" "$tmp/source.json" || fail 'late draft runtime not restored'
    cmp "$fixture/uci" "$fixture/original-uci" || fail 'late draft committed config not restored'
    cmp "$fixture/staged" "$fixture/draft-expected" || fail 'late DNS draft changed or erased'
    [ "$draft_point" != write ] || [ ! -e "$fixture/reloads" ] || fail 'early draft conflict restarted runtime'
done
echo 'PASS: late DNS drafts survive atomic-write and runtime-activation failure paths'
make_fixture foreign-committed
: > "$fixture/foreign-on-reload"
! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'foreign saved edit accepted'
jq -e '.error=="rollback_failed" and .restored==false' "$fixture/result" >/dev/null || fail 'foreign saved edit rollback claimed success'
grep -q '# foreign saved edit' "$fixture/uci" || fail 'foreign saved edit overwritten'
cp "$fixture/uci" "$fixture/foreign-expected"
! dns_apply_main rollback > "$fixture/result" || fail 'retry overwrote foreign saved edit'
cmp "$fixture/uci" "$fixture/foreign-expected" || fail 'retry changed foreign saved edit'
echo 'PASS: rollback and retry preserve foreign committed edits'
make_fixture success
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'apply failed'
jq -e '.success==true' "$fixture/result" >/dev/null || fail 'success reply'
jq -e '.continuity.kind=="dns-only" and .continuity.freshServiceEvidence==false' "$fixture/snapshot/snapshot.json" >/dev/null || fail 'continuity attribution missing'
jq -S 'del(.config,.policy,.continuity)|.sections|=map(del(.context))' "$fixture/snapshot/snapshot.json" > "$fixture/after-snapshot"
jq -S 'del(.config,.policy)|.sections|=map(del(.context))' "$fixture/original-snapshot" > "$fixture/before-snapshot"
cmp "$fixture/after-snapshot" "$fixture/before-snapshot" || fail 'admitted identity or service hashes changed'
cmp "$fixture/services" "$fixture/original-services" || fail 'freshness falsified'
reload_count="$(wc -l < "$fixture/reloads")"
backup_count="$(find "$fixture/backup" -type d -name 'transaction.*' | wc -l)"
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'idempotent apply failed'
jq -e '.success==true and .changed==false' "$fixture/result" >/dev/null || fail 'idempotent apply reported mutation'
[ "$(wc -l < "$fixture/reloads")" = "$reload_count" ] || fail 'idempotent apply reloaded'
[ "$(find "$fixture/backup" -type d -name 'transaction.*' | wc -l)" = "$backup_count" ] || fail 'idempotent apply created persistent backup'
echo 'PASS: idempotent apply avoids backup and process turnover'
: > "$fixture/reload-fail"
! dns_apply_main apply dot 9.9.9.10 tcp 8.8.8.8 > "$fixture/result" || fail 'second failed apply accepted'
dns_apply_main rollback > "$fixture/result" || fail 'explicit rollback failed'
assert_restored
echo 'PASS: apply continuity and explicit exact rollback'
make_fixture alias
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'alias fixture apply'
reload_count="$(wc -l < "$fixture/reloads")"
dns_apply_main apply dot alias.example tcp 8.8.8.8 > "$fixture/result" || fail 'alias-only UCI apply failed'
jq -e '.success==true and .changed==true' "$fixture/result" >/dev/null || fail 'alias-only UCI mutation misreported'
[ "$(wc -l < "$fixture/reloads")" = "$reload_count" ] || fail 'alias-only apply reloaded unchanged config'
dns_apply_main rollback > "$fixture/result" || fail 'alias-only rollback failed'
[ "$(wc -l < "$fixture/reloads")" = "$reload_count" ] || fail 'alias-only rollback reloaded unchanged config'
echo 'PASS: alias-only apply and rollback avoid process turnover'
for failure in invalid uci-write-fail reload-fail; do
    make_fixture "$failure"
    : > "$fixture/$failure"
    ! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail "$failure accepted"
    assert_restored
    [ "$failure" != invalid ] || [ ! -e "$fixture/reloads" ] || fail 'invalid candidate restarted'
done
echo 'PASS: validation atomic-write and reload failures preserved/restored exact files'
make_fixture rollback-fail
: > "$fixture/rollback-fail"
: > "$fixture/live-fail"
! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'broken rollback accepted'
jq -e '.error=="rollback_failed" and .restored==false' "$fixture/result" >/dev/null || fail 'rollback failure misreported'
assert_restored
echo 'PASS: rollback runtime failure reported truthfully'
make_fixture signal
: > "$fixture/signal"
! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'signal accepted'
assert_restored
jq -e '.error=="interrupted_rolled_back" and .restored==true' "$fixture/result" >/dev/null || fail 'signal recovery reply'
echo 'PASS: interruption restores before returning'

# Invalid predecessor state must never be repaired by prepare.
make_fixture missing-rule
jq --arg path "$fixture/rules/missing.json" '.route.rule_set=[{type:"local",path:$path}]' "$fixture/runtime.json" > "$fixture/new"
mv "$fixture/new" "$fixture/runtime.json"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'missing rule accepted'
[ ! -e "$fixture/rules/missing.json" ] && [ ! -e "$fixture/reloads" ] || fail 'prepare repaired RAM rules'
echo 'PASS: missing rules fail closed without restoring files'
make_fixture missing-snapshot-rule
generation="$(jq -r '.generation' "$fixture/snapshot/snapshot.json")"
printf '{}\n' > "$fixture/snapshot/$generation/extra.json"
digest="$(dns_apply_hash "$fixture/snapshot/$generation/extra.json")"
jq --arg digest "$digest" '.rules += [{name:"extra.json",sha:$digest}]' "$fixture/snapshot/snapshot.json" > "$fixture/new"
mv "$fixture/new" "$fixture/snapshot/snapshot.json"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'missing snapshot-only rule accepted'
[ ! -e "$fixture/rules/extra.json" ] || fail 'prepare restored snapshot-only missing rule'
echo 'PASS: snapshot-only missing rules fail closed without restoration'
make_fixture low-space
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 2000 1990 10 99%% /\n'; }
! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'low overlay capacity accepted'
unset -f df
assert_restored
[ ! -e "$fixture/reloads" ] || fail 'low capacity restarted runtime'
jq -e '.error=="insufficient_backup_space" and .changed==false' "$fixture/result" >/dev/null || fail 'low capacity error'
echo 'PASS: insufficient persistent backup capacity fails before mutation'
make_fixture pending-journal
: > "$fixture/rollback-fail"; : > "$fixture/live-fail"
! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'unhealthy pending fixture accepted'
pending_before="$(cat "$fixture/backup/pending")"
! dns_apply_main apply dot 9.9.9.10 tcp 8.8.8.8 > "$fixture/result" || fail 'new apply replaced outstanding recovery'
jq -e '.error=="pending_recovery_required" and .changed==false' "$fixture/result" >/dev/null || fail 'outstanding recovery was not guarded'
[ "$(cat "$fixture/backup/pending")" = "$pending_before" ] || fail 'pending recovery reference overwritten'
reload_count="$(wc -l < "$fixture/reloads")"
fixture_identity=fixture-process:2
rm "$fixture/rollback-fail" "$fixture/live-fail"
dns_apply_main rollback > "$fixture/result" || fail 'pending explicit recovery failed'
[ "$(wc -l < "$fixture/reloads")" -gt "$reload_count" ] || fail 'unknown loaded generation accepted during pending recovery'
unset fixture_identity
assert_restored
echo 'PASS: pending recovery does not infer loaded generation from restored files'
make_fixture generation-journal
DA_WORK="$fixture/journal"; mkdir "$DA_WORK"
printf '1|json|%s/runtime.json\n2|json|%s/root/workers/main/worker.json\n' "$fixture" "$fixture" > "$DA_WORK/files"
dns_apply_record_loaded || fail 'generation capture'
! dns_apply_needs_reload || fail 'unchanged loaded configuration needs turnover'
jq '.dns.servers[0].server="8.8.4.4"' "$fixture/root/workers/main/worker.json" > "$fixture/new"
mv "$fixture/new" "$fixture/root/workers/main/worker.json"
dns_apply_needs_reload || fail 'changed worker falsely accepted as loaded'
cp "$tmp/source.json" "$fixture/root/workers/main/worker.json"
fixture_identity=fixture-process:2
dns_apply_needs_reload || fail 'unknown PID generation accepted'
dns_apply_record_loaded || fail 'verified generation recapture'
! dns_apply_needs_reload || fail 'recaptured matching generation rejected'
unset fixture_identity
echo 'PASS: mixed changed and unknown PID generations require turnover'
make_fixture partial-explicit-rollback
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'partial rollback fixture apply'
eval "$(declare -f dns_apply_atomic | sed '1s/dns_apply_atomic/dns_apply_atomic_original/')"
dns_apply_atomic() {
    if [ -f "$fixture/restore-once-fail" ] && [ "$2" = "$fixture/runtime.json" ]; then
        rm "$fixture/restore-once-fail"; return 1
    fi
    dns_apply_atomic_original "$@"
}
: > "$fixture/restore-once-fail"
! dns_apply_main rollback > "$fixture/result" || fail 'partial explicit rollback accepted'
jq -e '.error=="rollback_failed" and .restored==false' "$fixture/result" >/dev/null || fail 'partial explicit rollback error'
partial_pending_exists=false
[ ! -s "$fixture/backup/pending" ] || partial_pending_exists=true
dns_apply_main rollback > "$fixture/result" || fail 'partial explicit rollback retry rejected by stale hash'
[ "$partial_pending_exists" = true ] || fail 'partial explicit rollback lost recovery reference'
assert_restored
echo 'PASS: partial explicit rollback refreshes bindings for recovery retry'
make_fixture pending-catalog
printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":false},{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","supported":true}]\n' > "$fixture/items"
printf 'pending main: keep current admitted pool\n' > "$fixture/pending-main"
sha256sum "$fixture/items" "$fixture/active" "$fixture/all" "$fixture/pending-main" > "$fixture/pending.sha"
dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'pending catalog blocked exact admitted DNS continuity'
assert_restored
sha256sum -c "$fixture/pending.sha" >/dev/null || fail 'pending catalog or selection mutated'
[ ! -e "$fixture/reloads" ] || fail 'pending catalog prepare reloaded runtime'
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'pending catalog blocked DNS-only successor'
sha256sum -c "$fixture/pending.sha" >/dev/null || fail 'DNS successor changed pending catalog or selection'
cmp "$fixture/services" "$fixture/original-services" || fail 'DNS successor renewed admitted evidence'
dns_apply_main rollback > "$fixture/result" || fail 'pending catalog blocked exact DNS rollback'
assert_restored
sha256sum -c "$fixture/pending.sha" >/dev/null || fail 'DNS rollback changed pending catalog or selection'
echo 'PASS: pending unsupported catalog does not reselect admitted runtime'
make_fixture invalid-continuity-context
jq '.sections[0].context="invalid-context"' "$fixture/snapshot/snapshot.json" > "$fixture/new"
mv "$fixture/new" "$fixture/snapshot/snapshot.json"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'invalid continuity context accepted'
make_fixture invalid-continuity-evidence
jq '.results[0].services.gemini.state="fail"' "$fixture/services" > "$fixture/new"
mv "$fixture/new" "$fixture/services"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'changed admitted evidence accepted'
make_fixture invalid-continuity-rule
printf '{"version":3,"rules":[]}\n' > "$fixture/rules/admitted.json"
jq --arg path "$fixture/rules/admitted.json" '.route.rule_set=[{type:"local",path:$path}]' "$fixture/runtime.json" > "$fixture/new"
mv "$fixture/new" "$fixture/runtime.json"
subscription_services_snapshot_save || fail 'rule continuity fixture snapshot'
printf 'corrupt\n' > "$fixture/rules/admitted.json"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'corrupt RAM admitted rule accepted'
printf '{"version":3,"rules":[]}\n' > "$fixture/rules/admitted.json"
generation="$(jq -r '.generation' "$fixture/snapshot/snapshot.json")"
printf 'corrupt\n' > "$fixture/snapshot/$generation/admitted.json"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'corrupt persistent admitted rule accepted'
echo 'PASS: continuity rejects changed context evidence RAM and persistent rules'
. "$repo/tests/dns_single_cases.sh"
fi

# Saved mode authenticates the exact deployed graph but deliberately does not
# bless any current UCI policy/context. Model only UCI's absolute-file parser.
dns_apply_saved_get() {
    awk -F= -v key="podkop.settings.$1" '$1==key{sub(/^[^=]*=/,"");print;found=1}END{exit !found}' "$PODKOP_DNS_APPLY_UCI_FILE"
}
eval "$(declare -f dns_apply_atomic | sed '1s/dns_apply_atomic/dns_apply_atomic_saved_original/')"
dns_apply_atomic() {
    case "$2" in "$fixture/uci"|"$fixture/root/context.sha256"|"$fixture/root/metadata.json")
        printf '%s\n' "$2" >> "$fixture/forbidden-writes"; return 1;; esac
    dns_apply_atomic_saved_original "$@"
}
for saved_case in success reload-fail concurrent-uci single-success single-reload-fail; do
    make_fixture "saved-$saved_case"
    saved_result="${saved_case#single-}"
    case "$saved_case" in single-*)
        printf '{"version":3,"mode":"single","sections":[{"section":"main","api_port":9090},{"section":"GEOBLOCK","api_port":9090}],"allocations":[]}\n' > "$fixture/root/metadata.json"
        printf 'single\n' > "$fixture/root/runtime-mode"
        printf 'dormant-worker\n' > "$fixture/root/workers/main/worker.json"
        jq --arg config "$(dns_apply_hash "$fixture/runtime.json")" '.config=$config|.sections=[]' "$fixture/snapshot/snapshot.json" > "$fixture/new"
        mv "$fixture/new" "$fixture/snapshot/snapshot.json"
        cp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot"
        sha256sum "$fixture/root/runtime-mode" "$fixture/root/metadata.json" "$fixture/root/workers/main/worker.json" > "$fixture/single-protected.sha"
        ;; esac
    printf 'podkop.settings.dns_server=new.example\npodkop.settings.dns_type=dot\npodkop.settings.bootstrap_dns_type=tcp\npodkop.settings.bootstrap_dns_server=8.8.8.8\npodkop.settings.unrelated=not-activated\n' > "$fixture/new-settings"
    awk -F= '$1!="podkop.settings.dns_server" && $1!="podkop.settings.dns_type" && $1!="podkop.settings.bootstrap_dns_type" && $1!="podkop.settings.bootstrap_dns_server"' "$fixture/uci" > "$fixture/new"
    cat "$fixture/new-settings" >> "$fixture/new"; mv "$fixture/new" "$fixture/uci"
    cp "$fixture/uci" "$fixture/saved-uci"
    printf 'podkop.main.subscription_selection_mode=selected\n' > "$fixture/staged"
    cp "$fixture/staged" "$fixture/saved-drafts"
    PODKOP_DNS_APPLY_SUBSCRIPTION_PENDING="$fixture/subscription.pending"
    printf 'unapplied subscription selection\n' > "$PODKOP_DNS_APPLY_SUBSCRIPTION_PENDING"
    cp "$PODKOP_DNS_APPLY_SUBSCRIPTION_PENDING" "$fixture/pending-before"
    jq '.results[0].services.gemini.state="fail"' "$fixture/services" > "$fixture/new"
    mv "$fixture/new" "$fixture/services"; cp "$fixture/services" "$fixture/saved-evidence"
    (
        . "$repo/openwrt/podkop-section-hooks.sh"
        DA_SAVED=1; DA_CONFIG="$fixture/runtime.json"
        config_get() { eval "$1=\"/draft/disabled-isolation.json\""; }
        [ "$(dns_apply_hash_production "$DA_CONFIG")" = "$(podkop_section_runtime_hash "$DA_CONFIG")" ] || fail 'saved graph hash depended on draft config_path/isolation'
        unset -f podkop_section_runtime_hash
        ! dns_apply_hash_production "$DA_CONFIG" || fail 'saved graph accepted missing compound hash helper'
    ) || fail 'real saved compound hash guard'
    dns_apply_main prepare dot new.example tcp 8.8.8.8 > "$fixture/result" || fail 'existing prepare did not route exact committed pair to saved continuation'
    cmp "$fixture/uci" "$fixture/saved-uci" || fail 'saved prepare modified current UCI'
    cmp "$fixture/staged" "$fixture/saved-drafts" || fail 'saved prepare modified drafts'
    if [ "$saved_result" != success ]; then
        : > "$fixture/reload-fail"
        if [ "$saved_case" = concurrent-uci ]; then
            : > "$fixture/edit-uci-on-reload"
            printf 'podkop.settings.concurrent=preserve\n' >> "$fixture/saved-uci"
        fi
        ! dns_apply_main apply-saved dot new.example tcp 8.8.8.8 > "$fixture/result" || fail 'saved reload failure accepted'
        cmp "$fixture/runtime.json" "$tmp/source.json" || fail 'saved failure did not restore runtime'
    else
        dns_apply_main apply dot new.example tcp 8.8.8.8 > "$fixture/result" || fail 'existing apply did not route exact committed pair to saved continuation'
        jq -e '.dns.servers[]|select(.tag=="dns-server")|.server=="new.example"' "$fixture/runtime.json" >/dev/null || fail 'saved DNS did not reach runtime'
        [ "$(cat "$fixture/root/context.sha256")" != "$(podkop_section_context_hash)" ] || fail 'unrelated saved drift was blessed as active'
        jq -S 'del(.config,.continuity)' "$fixture/snapshot/snapshot.json" > "$fixture/policy-after"
        jq -S 'del(.config,.continuity)' "$fixture/original-snapshot" > "$fixture/policy-before"
        cmp "$fixture/policy-after" "$fixture/policy-before" || fail 'saved transaction blessed current policy or section contexts'
        cmp "$fixture/services" "$fixture/saved-evidence" || fail 'saved mode fabricated fresh evidence'
        dns_apply_main rollback > "$fixture/result" || fail 'saved rollback failed'
        cmp "$fixture/runtime.json" "$tmp/source.json" || fail 'saved rollback did not restore runtime'
    fi
    cmp "$fixture/uci" "$fixture/saved-uci" || fail 'saved transaction modified current UCI'
    cmp "$fixture/staged" "$fixture/saved-drafts" || fail 'saved transaction modified subscription drafts'
    cmp "$PODKOP_DNS_APPLY_SUBSCRIPTION_PENDING" "$fixture/pending-before" || fail 'saved transaction modified pending selection marker'
    [ ! -e "$fixture/uci-mutations" ] && [ ! -e "$fixture/forbidden-writes" ] || fail 'saved transaction attempted UCI/context/metadata writes'
    [ ! -e "$fixture/single-protected.sha" ] || sha256sum -c "$fixture/single-protected.sha" >/dev/null || fail 'saved single changed worker or persistent mode'
done
unset PODKOP_DNS_APPLY_SUBSCRIPTION_PENDING
echo 'PASS: verified admitted DNS continuation preserves saved unrelated settings and subscription drafts'
