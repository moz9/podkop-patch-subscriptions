#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then tmp="$(cygpath -m "$tmp")"; fi
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$repo/openwrt/podkop-service-snapshot.sh" ] || fail 'safe admitted-runtime snapshot helper missing'
. "$repo/openwrt/podkop-service-snapshot.sh"
PODKOP_SERVICE_SNAPSHOT_DIR="$tmp/snapshot"
TMP_RULESET_FOLDER="$tmp/rules"
mkdir -p "$TMP_RULESET_FOLDER"
printf '{"version":3,"rules":[]}\n' > "$TMP_RULESET_FOLDER/user-main.json"
jq -cn --arg path "$TMP_RULESET_FOLDER/user-main.json" '{dns:{servers:[]},outbounds:[],route:{rule_set:[{type:"local",tag:"user-main",format:"source",path:$path}]}}' > "$tmp/config"
printf 'subscription-secret-proxy\n' > "$tmp/all"
printf 'subscription-secret-proxy\n' > "$tmp/active"
printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":true}]\n' > "$tmp/items"
printf '{"results":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","services":{"gemini":{"state":"pass"}}}]}\n' > "$tmp/services"
config_get() { case "$3" in config_path) eval "$1=\"\$tmp/config\"";; esac; }
config_foreach() { "$1" main; }
validate_subscription_urltest_section() { return 0; }
subscription_required_services_json() { printf '["gemini"]\n'; }
subscription_services_context() { printf 'context-one\n'; }
get_subscription_cache_path() { printf '%s/active\n' "$tmp"; }
get_subscription_all_cache_path() { printf '%s/all\n' "$tmp"; }
get_subscription_items_cache_path() { printf '%s/items\n' "$tmp"; }
get_subscription_link_id() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
subscription_services_cache_path() { printf '%s/services\n' "$tmp"; }
subscription_services_preflight() { [ "${proof_fresh:-1}" = 1 ]; }
subscription_services_policy() { printf '{"required":["gemini"],"results":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","services":{"gemini":{"state":"pass"}}}]}\n'; }
uci() { [ "$1:$2" = '-q:export' ] || return 1; printf 'config settings\n option secret %s\n option shutdown_correctly %s\n' "${policy_value:-private-config}" "${shutdown_value:-0}"; }
mkdir -p "$tmp/bin"
printf '#!/bin/sh\n[ "${TEST_CONFIG_VALID:-1}" = 1 ]\n' > "$tmp/bin/sing-box"
chmod 755 "$tmp/bin/sing-box"
snapshot_test_bin="$tmp/bin"
if command -v cygpath >/dev/null 2>&1; then snapshot_test_bin="$(cygpath -u "$snapshot_test_bin")"; fi
PATH="$snapshot_test_bin:$PATH"; export PATH
subscription_sing_box_reload_ready() { [ "${runtime_ready:-1}" = 1 ]; }
log() { :; }
subscription_services_snapshot_save || fail 'fresh verified runtime not captured'
cp "$tmp/config" "$tmp/original-config"
! grep -Rq 'subscription-secret\|private-config' "$PODKOP_SERVICE_SNAPSHOT_DIR" || fail 'snapshot leaks proxy or UCI secrets'
proof_fresh=0
before="$(sha256sum "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json")"
! subscription_services_snapshot_save || fail 'expired proof refreshed admitted snapshot'
[ "$before" = "$(sha256sum "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json")" ] || fail 'expired save modified snapshot'
subscription_services_snapshot_prepare || fail 'unchanged admitted runtime cannot be preserved'
cp "$tmp/services" "$tmp/original-services"
printf '{"results":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","services":{"gemini":{"state":"fail"}}}]}\n' > "$tmp/services"
! subscription_services_snapshot_prepare || fail 'new definitive failed check reused old admission'
cp "$tmp/original-services" "$tmp/services"
jq '.results += [{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",services:{gemini:{state:"unknown"}}}]' "$tmp/services" > "$tmp/new-services"
mv "$tmp/new-services" "$tmp/services"
subscription_services_snapshot_prepare || fail 'unrelated new unknown check broke admitted boot preservation'
cp "$tmp/original-services" "$tmp/services"
shutdown_value=1
subscription_services_snapshot_prepare || fail 'operational shutdown flag invalidated policy'
policy_value=changed
! subscription_services_snapshot_prepare || fail 'changed UCI policy reused admitted runtime'
unset policy_value
printf '[{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","supported":true}]\n' > "$tmp/items"
! subscription_services_snapshot_prepare || fail 'changed item identity reused admitted runtime'
printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":true}]\n' > "$tmp/items"
rm "$TMP_RULESET_FOLDER/user-main.json"
subscription_services_snapshot_prepare || fail 'RAM ruleset loss cannot recover exact admitted config'
[ -s "$TMP_RULESET_FOLDER/user-main.json" ] || fail 'ruleset not restored'
printf 'corrupt\n' > "$TMP_RULESET_FOLDER/user-main.json"
! subscription_services_snapshot_prepare || fail 'different existing ruleset overwritten'
printf '{"version":3,"rules":[]}\n' > "$TMP_RULESET_FOLDER/user-main.json"
runtime_ready=0; proof_fresh=1
! subscription_services_snapshot_save || fail 'failed runtime admitted snapshot'
runtime_ready=1; TEST_CONFIG_VALID=0; export TEST_CONFIG_VALID
! subscription_services_snapshot_save || fail 'invalid config admitted snapshot'
TEST_CONFIG_VALID=1
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 2000 1900 100 95%% /\n'; }
! subscription_services_snapshot_capacity || fail 'capacity preflight admitted a nearly-full overlay'
! subscription_services_snapshot_save || fail 'snapshot could fill a nearly-full overlay'
unset -f df
jq -cn --arg path "$tmp/outside.json" '{dns:{servers:[]},outbounds:[],route:{rule_set:[{type:"local",path:$path}]}}' > "$tmp/config"
printf 'private-outside-file\n' > "$tmp/outside.json"
! subscription_services_snapshot_save || fail 'snapshot copied an arbitrary file outside the ruleset folder'
cp "$tmp/original-config" "$tmp/config"
proof_fresh=0
check_requirements() { :; }
migration() { :; }
process_validate_service() { :; }
br_netfilter_disable() { :; }
route_table_rule_mark() { :; }
create_nft_rules() { :; }
restore_cached_community_subnet_lists() { :; }
community_subnet_lists_enabled() { return 1; }
sing_box_configure_service() { :; }
remove_cron_job() { :; }
add_cron_job() { :; }
add_subscription_cron_job() { :; }
sing_box_configure_log() { :; }
sing_box_configure_inbounds() { :; }
sing_box_configure_outbounds() { touch "$tmp/generated"; }
sing_box_configure_dns() { :; }
sing_box_configure_route() { :; }
sing_box_configure_experimental() { :; }
sing_box_additional_inbounds() { :; }
sing_box_save_config() { :; }
snapshot_test_daemon_start() { touch "$tmp/daemon-started"; }
PODKOP_SKIP_LIST_UPDATE=1
TMP_SING_BOX_FOLDER="$tmp/sb"
eval "$(sed -n '/^sing_box_init_config() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop")"
eval "$(sed -n '/^start_main() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop" | sed 's|/usr/sbin/ntpd .*|:|;s|/etc/init.d/sing-box start|snapshot_test_daemon_start|')"
start_main || fail 'expired-proof boot did not preserve admitted runtime'
[ -e "$tmp/daemon-started" ] || fail 'preserved runtime not started'
[ ! -e "$tmp/generated" ] || fail 'expired proof was used to build a new candidate'
[ "$before" = "$(sha256sum "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json")" ] || fail 'preservation refreshed snapshot'
policy_value=changed
rm "$tmp/daemon-started"
start_main && fail 'changed-policy boot reused snapshot' || :
[ ! -e "$tmp/daemon-started" ] || fail 'changed-policy boot started stale runtime'
unset policy_value
proof_fresh=1
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 2000 1900 100 95%% /\n'; }
start_main && fail 'required-filter start reported success without a safe snapshot' || :
unset -f df
cp "$tmp/original-config" "$tmp/config"
cp "$tmp/original-config" "$tmp/candidate"
printf '\n' >> "$tmp/candidate"
sing_box_init_config() { cp "$tmp/candidate" "$tmp/config"; }
subscription_reload_pending_file() { printf '%s/pending\n' "$tmp"; }
subscription_sing_box_pid() { printf '42\n'; }
subscription_signal_sing_box_reload() { printf 'signal\n' >> "$tmp/signals"; }
echolog() { :; }
PODKOP_SUBSCRIPTION_APPLY_NOW=1
PODKOP_SUBSCRIPTION_RELOAD_DELAY=0
eval "$(sed -n '/^subscription_reload_seamless() {$/,/^}$/p' "$repo/openwrt/runtime-0.7.22/usr/bin/podkop")"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 2000 1900 100 95%% /\n'; }
subscription_reload_seamless && fail 'new filter activation reported success when snapshot could not fit' || :
cmp -s "$tmp/config" "$tmp/original-config" || fail 'snapshot failure did not restore last working config'
[ "$before" = "$(sha256sum "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json")" ] || fail 'failed activation blessed a new snapshot'
[ "$(wc -l < "$tmp/signals")" -eq 2 ] || fail 'rollback did not signal restored config'
unset -f df
printf '\n' >> "$tmp/config"
! subscription_services_snapshot_prepare || fail 'different full config reused snapshot'
subscription_required_services_json() { printf '[]\n'; }
subscription_services_snapshot_save || fail 'default-off mode was affected by snapshot constraints'
[ "$before" = "$(sha256sum "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json")" ] || fail 'default-off mode rewrote snapshot'
# Exercise the actual row emitter without thousands of per-node probe/fork operations.
links="$(jq -cn '[range(0;2048) | {id:(("00000000000000000000000000000000"+tostring)[-32:]),sha:("a"*64)}]')"
ids="$(printf '%s' "$links" | jq -c 'map(.id)')"
section=main; context=large-fixture; service_sha=proof-fixture
SNAPSHOT_SECTIONS="$tmp/large-row"; SNAPSHOT_FAILED=0
snapshot_test_emitter="$(awk '/^[ ]*(jq -cn|printf.*jq -c).*--arg section/ {emit=1} emit {print} emit && /SNAPSHOT_SECTIONS/ {exit}' "$repo/openwrt/podkop-service-snapshot.sh")"
[ -n "$snapshot_test_emitter" ] || fail 'snapshot row emitter missing'
eval "$snapshot_test_emitter"
[ "$SNAPSHOT_FAILED" = 0 ] || fail 'large admitted snapshot exceeded process argument limits'
jq -e '.section=="main" and (.admittedLinks|length)==2048 and (.admittedIds|length)==2048 and .admittedIds==(.admittedLinks|map(.id))' "$SNAPSHOT_SECTIONS" >/dev/null || fail 'large admitted snapshot changed identities'
echo 'PASS: exact admitted-runtime boot preservation, policy/cache/config gates, private metadata and RAM ruleset recovery'
