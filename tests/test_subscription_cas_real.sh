#!/bin/bash
set -eo pipefail
repo=${1:-$(cd "$(dirname "$0")/.." && pwd)}
version=${2:-${PODKOP_TEST_VERSION:-0.7.24}}
evidence=${PODKOP_TEST_UCI_EVIDENCE:-}
if [ -n "$evidence" ]; then
 uci_binary="$evidence/build/bin/uci"
 openwrt_functions="$evidence/openwrt-functions.sh"
 openwrt_uci="$evidence/openwrt-uci.sh"
else
 uci_binary=$(command -v uci || true)
 openwrt_functions=/lib/functions.sh
 openwrt_uci=/lib/config/uci.sh
fi
if [ ! -x "$uci_binary" ] || [ ! -r "$openwrt_functions" ] || [ ! -r "$openwrt_uci" ]; then
 echo 'SKIP real UCI CAS: set PODKOP_TEST_UCI_EVIDENCE to the official UCI build/wrapper fixture directory.'
 exit 0
fi
work=$(mktemp -d /tmp/podkop-cas-test-XXXXXX)
trap 'rm -rf "$work"' EXIT
runtime=$repo/openwrt/runtime-$version/usr/bin/podkop
mkdir "$work/config" "$work/shared" "$work/cache"
export PODKOP_CONFIG=$work/config/podkop SUBSCRIPTION_CACHE_DIR=$work/cache
export PODKOP_SUBSCRIPTION_CAS_DNS_CONFIG=$work/dns
export PODKOP_SERVICE_CACHE_DIR=$work/services
printf '{"dns":{"servers":[]}}\n' > "$work/dns"
cat > "$PODKOP_CONFIG" <<'CFG'
config settings 'settings'
 option dns_type 'plain'
config section 'main'
 option connection_type 'proxy'
 option proxy_config_type 'subscription_urltest'
 list subscription_url 'https://example.invalid/a'
config section 'peer'
 option connection_type 'proxy'
 option proxy_config_type 'subscription_urltest'
 list subscription_url 'https://example.invalid/b'
CFG
uci() { "$uci_binary" -c "$work/config" -p "$work/shared" -t "$work/shared" "$@"; }
uci set podkop.main.unrelated=shared-unsaved
uci set podkop.main.subscription_selection_mode=selected
cp "$work/shared/podkop" "$work/shared-before"
cat > "$work/uci-wrapper" <<LAUNCH
#!/bin/sh
exec "$uci_binary" -c "$work/config" -p "$work/shared" -t "$work/shared" "\$@"
LAUNCH
chmod +x "$work/uci-wrapper"
sed "s|/sbin/uci|$work/uci-wrapper|g" "$openwrt_uci" > "$work/uci.sh"
. "$openwrt_functions"
. "$work/uci.sh"
. "$repo/openwrt/podkop-subscription-sources.sh"
sed -n '/^# subscription_apply_v2 begin$/,/^# subscription_apply_v2 end$/p' "$runtime" > "$work/backend"
for fn in get_subscription_cache_path get_subscription_skipped_cache_path get_subscription_all_cache_path get_subscription_items_cache_path collect_subscription_urls append_subscription_url_to_file collect_subscription_excluded_ids append_subscription_excluded_id_to_file validate_subscription_section_name validate_subscription_urltest_section validate_subscription_link_id get_subscription_link_id apply_subscription_exclusions_to_cached_links subscription_pending_sections_json subscription_pending_mark subscription_pending_clear normalize_subscription_enabled_value set_subscription_links_enabled set_subscription_link_enabled subscription_services_cache_path subscription_services_catalog subscription_services_validate subscription_required_services_json; do
 sed -n "/^$fn() {$/,/^}$/p" "$runtime" >> "$work/backend"
done
. "$work/backend"
subscription_runtime_busy() { return 1; }
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { :; }
subscription_reload_pending_file() { echo "$work/pending"; }
subscription_apply_v2_reload() { echo reload >> "$work/reloads"; [ ! -f "$work/reload-fail" ]; }
get_subscription_services() { printf '{"success":true,"requiredServices":[],"catalog":[],"results":[]}\n'; }
subscription_services_policy() { printf '{"required":[],"results":[]}\n'; }
alpha=$(get_subscription_link_id alpha); beta=$(get_subscription_link_id beta)
for section in main peer; do
 jq -cn --arg a "$alpha" --arg b "$beta" '[{id:$a,selectionId:$a,supported:true,name:"FI node",sourceIndex:1},{id:$b,selectionId:$b,supported:true,name:"US node",sourceIndex:1}]' > "$(get_subscription_items_cache_path "$section")"
 printf 'alpha\nbeta\n' > "$(get_subscription_all_cache_path "$section")"
 printf 'alpha\nbeta\n' > "$(get_subscription_cache_path "$section")"
done
fail() { echo "FAIL $*" >&2; exit 1; }
snapshot() { get_subscription_snapshot; }
rev() { snapshot | jq -er --arg s "$1" '.sections[]|select(.code==$s)|.revision'; }
payload() { jq -cn --arg s "$1" --arg r "$2" --arg tag "$3" '{sections:[{section:$s,expectedRevision:$r,changes:[],includeTags:[$tag]}]}'; }
config_load podkop
result=$(snapshot) || { echo "$result"; fail snapshot; }
echo "$result" | jq -e '.success and (.sections|length==2) and all(.sections[]; .selectionMode=="auto")' >/dev/null || fail snapshot-shape
main=$(echo "$result" | jq -r '.sections[]|select(.code=="main")|.revision')
peer=$(echo "$result" | jq -r '.sections[]|select(.code=="peer")|.revision')
result=$(set_subscription_sections_enabled "$(payload main "$main" 'FI*')" || true)
echo "$result" | jq -e '.error=="uci_pending_changes" and .committed==false' >/dev/null || fail shared-delta-refusal
cmp "$work/shared/podkop" "$work/shared-before" || fail shared-delta-mutated
mv "$work/shared/podkop" "$work/shared-held"
result=$(set_subscription_sections_enabled "$(payload main "$main" 'FI*')") || { echo "$result"; fail first-apply; }
echo "$result" | jq -e '.success and .committed' >/dev/null || fail first-result
before=$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR"/*)
result=$(set_subscription_sections_enabled "$(payload main "$main" 'US*')" || true)
echo "$result" | jq -e '.success==false and .error=="revision_conflict" and .committed==false' >/dev/null || { echo "$result"; fail stale; }
[ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR"/*)" ] || fail stale-wrote
result=$(set_subscription_sections_enabled "$(payload peer "$peer" 'US*')") || { echo "$result"; fail peer-independent; }
cmp "$work/shared-held" "$work/shared-before" || fail shared-delta-changed
! grep -q shared-unsaved "$PODKOP_CONFIG" || fail shared-delta-committed
result=$(set_subscription_sections_enabled '{"sections":[{"section":"main","changes":[],"includeTags":["US*"]}]}' || true)
echo "$result" | jq -e '.error=="revision_required" and .committed==false' >/dev/null || fail legacy
result=$(set_subscription_link_enabled main "$alpha" 1 || true)
echo "$result" | jq -e '.error=="revision_required"' >/dev/null || fail legacy-wrapper
result=$(set_subscription_sections_enabled "$(payload main bad 'FI*')" || true)
echo "$result" | jq -e '.error=="invalid_revision"' >/dev/null || fail malformed
# A stale member aborts an otherwise current multi-section transaction.
current=$(rev main); current_peer=$(rev peer)
multi=$(jq -cn --arg a "$current" --arg b "$peer" '{sections:[{section:"main",expectedRevision:$a,changes:[],includeTags:["US*"]},{section:"peer",expectedRevision:$b,changes:[],includeTags:["FI*"]}]}')
before=$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR"/*)
result=$(set_subscription_sections_enabled "$multi" || true)
echo "$result" | jq -e '.error=="revision_conflict" and .committed==false' >/dev/null || fail mixed-stale
[ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR"/*)" ] || fail mixed-wrote
# Set-valued filters normalize order and duplicates; ordered lists remain meaningful.
uci set "$PODKOP_CONFIG.main.subscription_include_tags=FI*"
uci delete "$PODKOP_CONFIG.main.subscription_include_tags"
uci add_list "$PODKOP_CONFIG.main.subscription_include_tags=FI*"
uci add_list "$PODKOP_CONFIG.main.subscription_include_tags=US*"
normal=$(rev main)
uci delete "$PODKOP_CONFIG.main.subscription_include_tags"
uci add_list "$PODKOP_CONFIG.main.subscription_include_tags=US*"
uci add_list "$PODKOP_CONFIG.main.subscription_include_tags=FI*"
uci add_list "$PODKOP_CONFIG.main.subscription_include_tags=FI*"
[ "$normal" = "$(rev main)" ] || fail normalized-sets
uci add_list "$PODKOP_CONFIG.main.community_lists=first"
uci add_list "$PODKOP_CONFIG.main.community_lists=second"
ordered=$(rev main)
uci delete "$PODKOP_CONFIG.main.community_lists"
uci add_list "$PODKOP_CONFIG.main.community_lists=second"
uci add_list "$PODKOP_CONFIG.main.community_lists=first"
[ "$ordered" != "$(rev main)" ] || fail ordered-context
# Different-section saved changes do not alter the current main revision.
current=$(rev main)
uci set "$PODKOP_CONFIG.peer.label=new-peer-label"
[ "$current" = "$(rev main)" ] || fail unrelated-section-conflict
# Source rotation and node/credential identities are part of the base.
uci add_list "$PODKOP_CONFIG.main.subscription_url=https://example.invalid/rotated"
[ "$current" != "$(rev main)" ] || fail changed-source
current=$(rev main)
printf 'credential-rotated\n' >> "$(get_subscription_all_cache_path main)"
[ "$current" != "$(rev main)" ] || fail changed-credential
current=$(rev main)
jq '.[0].name="renamed"' "$(get_subscription_items_cache_path main)" > "$work/items-new"
mv "$work/items-new" "$(get_subscription_items_cache_path main)"
[ "$current" != "$(rev main)" ] || fail changed-label
# Stored evidence changes invalidate; the passage of time itself does not.
mkdir -p "$PODKOP_SERVICE_CACHE_DIR"
printf '{"context":"proof-context","results":[]}\n' > "$PODKOP_SERVICE_CACHE_DIR/main.json"
proof=$(rev main); sleep 1
[ "$proof" = "$(rev main)" ] || fail clock-hashed
printf '{"context":"other-proof-context","results":[]}\n' > "$PODKOP_SERVICE_CACHE_DIR/main.json"
[ "$proof" != "$(rev main)" ] || fail changed-proof
# Malformed/ambiguous cache fails closed, without returning a partial snapshot.
cp "$(get_subscription_items_cache_path main)" "$work/items-before"
jq '.+[.[0]]' "$work/items-before" > "$(get_subscription_items_cache_path main)"
result=$(snapshot || true)
echo "$result" | jq -e '.success==false and (has("sections")|not)' >/dev/null || fail duplicate-cache
cp "$work/items-before" "$(get_subscription_items_cache_path main)"
# Resource refusal occurs before a large canonical JSON operation.
printf 'MemAvailable: 1 kB\n' > "$work/lowmem"
result=$(PODKOP_SUBSCRIPTION_MEMINFO_FILE="$work/lowmem" snapshot || true)
echo "$result" | jq -e '.success==false' >/dev/null || fail low-memory
# External commit between validation and publish must survive unchanged.
current=$(rev main)
eval "$(declare -f subscription_cas_publish | sed '1s/subscription_cas_publish/original_cas_publish/')"
subscription_cas_publish() { uci set "$PODKOP_CONFIG.main.external=changed-during-validation"; cp "$PODKOP_CONFIG" "$work/external-config"; original_cas_publish; }
result=$(set_subscription_sections_enabled "$(payload main "$current" 'US*')" || true)
echo "$result" | jq -e '.error=="revision_conflict" and .committed==false' >/dev/null || { echo "$result"; fail external; }
cmp "$PODKOP_CONFIG" "$work/external-config" || fail external-overwritten
unset -f subscription_cas_publish
eval "$(declare -f original_cas_publish | sed '1s/original_cas_publish/subscription_cas_publish/')"
# Reload failure restores committed config/cache; shared staged deltas stay intact.
current=$(rev main); cp "$PODKOP_CONFIG" "$work/rollback-config"
before=$(sha256sum "$SUBSCRIPTION_CACHE_DIR"/*)
touch "$work/reload-fail"
result=$(set_subscription_sections_enabled "$(payload main "$current" 'US*')" || true)
echo "$result" | jq -e '.success==false and .committed==true' >/dev/null || { echo "$result"; fail reload-failure; }
cmp "$PODKOP_CONFIG" "$work/rollback-config" || fail rollback-config
[ "$before" = "$(sha256sum "$SUBSCRIPTION_CACHE_DIR"/*)" ] || fail rollback-cache
cmp "$work/shared-held" "$work/shared-before" || fail shared-delta-changed-late
rm -f "$work/reload-fail"
# Signals after actual rename must report committed rollback and restore all bytes.
current=$(rev main); cp "$PODKOP_CONFIG" "$work/signal-before"
before=$(sha256sum "$SUBSCRIPTION_CACHE_DIR"/*)
subscription_cas_publish() {
 original_cas_publish || return
 read -r actual ignored < /proc/self/stat
 kill -TERM "$actual"
}
result=$(set_subscription_sections_enabled "$(payload main "$current" '*')") || true
echo "$result" | jq -e '.phase=="interrupted" and .committed==true and .rolledBack==true' >/dev/null || { echo "$result"; fail publication-signal; }
cmp "$PODKOP_CONFIG" "$work/signal-before" || fail publication-signal-config
[ "$before" = "$(sha256sum "$SUBSCRIPTION_CACHE_DIR"/*)" ] || fail publication-signal-cache
unset -f subscription_cas_publish
eval "$(declare -f original_cas_publish | sed '1s/original_cas_publish/subscription_cas_publish/')"
# Private-stage and private-commit failures cannot alter live committed state.
eval "$(declare -f subscription_cas_uci | sed '1s/subscription_cas_uci/original_cas_uci/')"
for failure in add_list commit; do
 subscription_cas_uci() {
  local operation="$1"; [ "$operation" != -q ] || operation="$2"
  [ "$operation" != "$failure" ] || return 1
  original_cas_uci "$@"
 }
 current=$(rev main); cp "$PODKOP_CONFIG" "$work/fail-before"
 result=$(set_subscription_sections_enabled "$(payload main "$current" '*')" || true)
 echo "$result" | jq -e '.success==false and .committed==false' >/dev/null || fail private-write-failure
 cmp "$PODKOP_CONFIG" "$work/fail-before" || fail private-write-leaked
done
unset -f subscription_cas_uci
eval "$(declare -f original_cas_uci | sed '1s/original_cas_uci/subscription_cas_uci/')"
# Existing service admission still rejects expired proof with a current revision.
for fn in subscription_services_read subscription_services_policy get_subscription_services subscription_services_error; do
 sed -n "/^$fn() {$/,/^}$/p" "$runtime" >> "$work/service-real"
done
. "$work/service-real"
subscription_services_context() { echo cas-test-context; }
subscription_services_country_map() { echo '{}'; }
subscription_services_snapshot_capacity() { return 0; }
jq -cn --arg id "$alpha" '{context:"cas-test-context",results:[{id:$id,checkedAt:1,expiresAt:2,services:{chatgpt:{state:"pass",checkedAt:1,expiresAt:2}}}]}' > "$PODKOP_SERVICE_CACHE_DIR/main.json"
current=$(rev main); cp "$PODKOP_CONFIG" "$work/expired-before"
request=$(jq -cn --arg r "$current" '{sections:[{section:"main",expectedRevision:$r,changes:[],includeTags:["*"],requiredServices:["chatgpt"]}]}')
result=$(set_subscription_sections_enabled "$request" || true)
echo "$result" | jq -e '.success==false and .committed==false and (.error=="service_results_stale_or_missing" or .error=="service_no_eligible_nodes")' >/dev/null || { echo "$result"; fail expired-proof; }
cmp "$PODKOP_CONFIG" "$work/expired-before" || fail expired-proof-write
# Failed identity hashing never produces an apparently usable revision.
sha256sum() { case "$1" in *.all.links) return 1;; esac; command sha256sum "$@"; }
result=$(snapshot || true)
echo "$result" | jq -e '.success==false and (has("sections")|not)' >/dev/null || fail failed-hash-accepted
unset -f sha256sum
# Real shared lock prevents a mixed read and cannot be stolen by snapshot cleanup.
sed -n '/^subscription_action_lock_file() {$/,/^# sing-box funcs$/p' "$runtime" | sed '$d' > "$work/real-lock"
. "$work/real-lock"
subscription_action_lock_file() { echo "$work/legacy-lock"; }
subscription_action_lock_dir() { echo "$work/action-lock"; }
mkdir "$work/action-lock"; printf '%s busy-owner\n' "$$" > "$work/action-lock/owner"
result=$(snapshot || true)
echo "$result" | jq -e '.error=="service_busy" and .committed==false' >/dev/null || fail snapshot-lock
[ -f "$work/action-lock/owner" ] || fail snapshot-stole-lock
rm -rf "$work/action-lock"
# First-load sections are coherent empty rows; malformed existing JSON is not.
rm -f "$(get_subscription_items_cache_path peer)" "$(get_subscription_all_cache_path peer)" "$work/dns"
result=$(snapshot)
echo "$result" | jq -e '.success and any(.sections[]; .code=="peer" and .items==[] and (.revision|length==64))' >/dev/null || fail uninitialized-section
# Removed sections cannot reuse residual config_get variables from an earlier load.
config_load "$PODKOP_CONFIG"
peer_old=$(rev peer)
uci delete "$PODKOP_CONFIG.peer"
result=$(set_subscription_sections_enabled "$(payload peer "$peer_old" '*')" || true)
echo "$result" | jq -e '.error=="revision_conflict" and .committed==false' >/dev/null || fail deleted-section
printf 'PASS real UCI CAS: concurrency, policy/proof/source identity, private staging, rollback/interruption, low memory, locks, bootstrap and failed hashing\n'
