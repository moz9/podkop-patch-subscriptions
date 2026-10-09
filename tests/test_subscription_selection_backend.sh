#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-subscription-sources.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
if sed -n '/^subscription_source_policy() {/,/^}/p' "$repo/openwrt/podkop-subscription-sources.sh" | grep -Eq '(^|[^[:alnum:]_])(gsub|test|match|sub)\('; then
 fail 'tag policy must not require jq regex builtins (router jq lacks Oniguruma)'
fi
printf '%s\n' '[{"id":"current","selectionId":"stable","supported":true,"sourceIds":["s"]},{"id":"new","supported":true,"sourceIds":["s"]}]' > "$work/policy.items"
subscription_source_policy '[]' '[]' "$work/policy.items" selected '["stable"]' | jq -e '.[0].enabled and (.[1].enabled|not)' >/dev/null || fail 'selected mode must enable only stable selected identities'
subscription_source_policy '["s"]' '[]' "$work/policy.items" selected '["stable"]' | jq -e '.[0].enabled and (.[0].runtimeEnabled|not)' >/dev/null || fail 'disabled source must retain selected choice'
subscription_source_policy '[]' '["stable"]' "$work/policy.items" | jq -e '(.[0].enabled|not) and .[1].enabled' >/dev/null || fail 'default blacklist mode changed'
jq '.[0] += {name:"Node",protocol:"vless",connectionKey:"connection"}' "$work/policy.items" > "$work/identity.old"
jq '.[0] += {id:"rotated",name:"Renamed",protocol:"vless",connectionKey:"connection"}' "$work/policy.items" > "$work/identity.new"
subscription_reconcile_choices "$work/identity.old" "$work/identity.new" > "$work/identity.result"
subscription_source_policy '[]' '[]' "$work/identity.result" selected '["stable"]' | jq -e '.[0].selectionId=="stable" and .[0].enabled and (.[1].enabled|not)' >/dev/null || fail 'rotated identity lost its selected preference'

printf '%s\n' '[{"id":"one","name":"🇷🇺 Москва 1","supported":true},{"id":"two","name":"US [fast] $HOME; touch nope","supported":true},{"id":"three","name":"🇷🇺 Москва 2","supported":true}]' > "$work/tag.items"
subscription_source_policy '[]' '[]' "$work/tag.items" all '[]' '["🇷🇺 Москва ?","US [fast] $HOME; touch nope"]' '["*2"]' \
 | jq -e '.[0].runtimeEnabled and (.[1].runtimeEnabled|not) and (.[2].runtimeEnabled|not) and .[1].tagExcluded and .[2].tagExcluded and .[0].enabled and .[1].enabled and .[2].enabled' >/dev/null || fail 'tag glob policy must gate runtime without changing node choices'
subscription_source_policy '[]' '[]' "$work/tag.items" all '[]' '["*","US [fast] $HOME; touch nope"]' '["🇷🇺 Москва [12]"]' \
 | jq -e '.[0].tagExcluded and (.[1].tagExcluded|not) and .[2].tagExcluded' >/dev/null || fail 'excluded character class must win and literal shell text must remain data'
printf '%s\n' '[{"id":"poland","name":"🇵🇱 Польша ⚡️ ","supported":true}]' > "$work/trailing.items"
subscription_source_policy '[]' '[]' "$work/trailing.items" all '[]' '["🇵🇱 Польша ⚡️ "]' '[]' \
 | jq -e '.[0].runtimeEnabled' >/dev/null || fail 'exact source name with trailing whitespace must match'
printf '%s\n' '[{"id":"unicode","name":"🇷🇺 Россия","supported":true},{"id":"range","name":"Node 7","supported":true},{"id":"literal","name":"Cost $HOME;*?","supported":true},{"id":"bracket","name":"A[bc","supported":true}]' > "$work/glob.items"
subscription_source_policy '[]' '[]' "$work/glob.items" all '[]' '["?? Россия","Node [0-9]","Cost $HOME;[*][?]","A[bc"]' '[]' \
 | jq -e 'all(.[]; .runtimeEnabled)' >/dev/null || fail 'regex-free glob must match Unicode codepoints, ranges, class literals and unmatched bracket literally'
printf '%s\n' '[{"id":"tag-only","tag":"Node x","supported":true},{"id":"bracket","name":"A[bc]","supported":true}]' > "$work/tag-fallback.items"
subscription_source_policy '[]' '[]' "$work/tag-fallback.items" all '[]' '["Node [!0-9]","A\\[bc\\]"]' '[]' \
 | jq -e 'all(.[]; .runtimeEnabled)' >/dev/null || fail 'tag fallback, negated class and escaped brackets must match'

# Exercise the real transaction and cache policy; only UCI and reload are private substitutes.
for version in 0.7.20 0.7.22; do
 runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
 sed -n '/^# subscription_apply_v2 begin$/,/^# subscription_apply_v2 end$/p' "$runtime" > "$work/backend"
 for name in apply_subscription_exclusions_to_cached_links set_subscription_links_enabled normalize_subscription_enabled_value; do
   sed -n "/^$name() {$/,/^}$/p" "$runtime" >> "$work/backend"
 done
 . "$work/backend"
 PODKOP_CONFIG="$work/config"
 SUBSCRIPTION_CACHE_DIR="$work/cache"
 mkdir -p "$SUBSCRIPTION_CACHE_DIR"
 printf '{"main":{},"peer":{}}\n' > "$PODKOP_CONFIG"
 config_get() {
   local value
   value="$(jq -r --arg s "$2" --arg k "$3" '.[$s][$k] // "" | if type=="array" then join(" ") else . end' "$PODKOP_CONFIG")"
   eval "$1=\$value"
 }
 config_list_foreach() {
   local entry
   jq -r --arg s "$1" --arg k "$2" '.[$s][$k] // [] | .[]' "$PODKOP_CONFIG" > "$PODKOP_CONFIG.list"
   while IFS= read -r entry; do "$3" "$entry"; done < "$PODKOP_CONFIG.list"
 }
 config_load() { :; }
 uci() {
   [ "$1" != -q ] || shift
   local command="$1" key="${2:-}" section option value stage="$PODKOP_CONFIG.stage"
   case "$command" in
   revert) rm -f "$stage"; return 0;;
   commit) mv "$stage" "$PODKOP_CONFIG"; echo commit >> "$work/commits"; return 0;;
   esac
   [ -f "$stage" ] || cp "$PODKOP_CONFIG" "$stage"
   key="${key#podkop.}"; section="${key%%.*}"; key="${key#*.}"; option="${key%%=*}"; value="${key#*=}"
   case "$command" in
   delete) jq --arg s "$section" --arg k "$option" 'del(.[$s][$k])' "$stage" > "$stage.next";;
   set) jq --arg s "$section" --arg k "$option" --arg v "$value" '.[$s][$k]=$v' "$stage" > "$stage.next";;
   add_list) jq --arg s "$section" --arg k "$option" --arg v "$value" '.[$s][$k]=((.[$s][$k]//[])+[$v])' "$stage" > "$stage.next";;
   *) return 1;;
   esac
   mv "$stage.next" "$stage"
 }
 validate_subscription_section_name() { case "$1" in main|peer) return 0;; *) return 1;; esac; }
 validate_subscription_urltest_section() { validate_subscription_section_name "$1"; }
 validate_subscription_link_id() { [ "${#1}" -eq 32 ] && ! printf '%s' "$1" | grep -q '[^a-f0-9]'; }
 get_subscription_link_id() { printf '%s' "$1" | md5sum | cut -d ' ' -f 1; }
 get_subscription_items_cache_path() { echo "$SUBSCRIPTION_CACHE_DIR/$1.items"; }
 get_subscription_all_cache_path() { echo "$SUBSCRIPTION_CACHE_DIR/$1.all"; }
 get_subscription_cache_path() { echo "$SUBSCRIPTION_CACHE_DIR/$1.links"; }
 collect_subscription_excluded_ids() { jq -r --arg s "$1" '.[$s].subscription_excluded_link_ids//[] | .[]' "$PODKOP_CONFIG" > "$2"; }
 collect_subscription_urls() { printf '%s\n' source-one source-two > "$2"; }
 subscription_runtime_busy() { return 1; }
 subscription_action_lock_acquire() { return 0; }
 subscription_action_lock_release() { :; }
 subscription_reload_pending_file() { echo "$work/pending"; }
 subscription_apply_v2_reload() { echo reload >> "$work/reloads"; [ ! -f "$work/fail-reload" ] || { rm "$work/fail-reload"; return 1; }; }
 one="$(get_subscription_link_id source-one)"; two="$(get_subscription_link_id source-two)"
 a="$(get_subscription_link_id alpha)"; b="$(get_subscription_link_id beta)"; c="$(get_subscription_link_id gamma)"; stable=11111111111111111111111111111111
 jq -n --arg a "$a" --arg b "$b" --arg c "$c" --arg stable "$stable" --arg one "$one" --arg two "$two" '[{id:$a,selectionId:$stable,supported:true,sourceIds:[$one]},{id:$b,supported:true,sourceIds:[$one]},{id:$c,supported:true,sourceIds:[$two]}]' > "$SUBSCRIPTION_CACHE_DIR/main.items"
 printf '%s\n' alpha beta gamma > "$SUBSCRIPTION_CACHE_DIR/main.all"
 printf '%s\n' alpha beta > "$SUBSCRIPTION_CACHE_DIR/main.links"
 cp "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/peer.items"
 cp "$SUBSCRIPTION_CACHE_DIR/main.all" "$SUBSCRIPTION_CACHE_DIR/peer.all"
 printf '%s\n' beta > "$SUBSCRIPTION_CACHE_DIR/peer.links"
 jq --arg two "$two" --arg b "$b" '.main.subscription_disabled_source_ids=[$two] | .peer={subscription_selection_mode:"selected",subscription_selected_link_ids:[$b]}' "$PODKOP_CONFIG" > "$PODKOP_CONFIG.next"; mv "$PODKOP_CONFIG.next" "$PODKOP_CONFIG"
 peer_before="$(jq -c '.peer' "$PODKOP_CONFIG")"
 payload="$(jq -cn --arg b "$b" '{sections:[{section:"main",selectionMode:"selected",changes:[{id:$b,enabled:false}]}]}')"
 result="$(set_subscription_sections_enabled "$payload")"
 printf '%s' "$result" | jq -e '.success and .committed and .changed==2' >/dev/null || fail 'mode and toggles must apply together'
 jq -e --arg stable "$stable" '.main.subscription_selection_mode=="selected" and .main.subscription_selected_link_ids==[$stable]' "$PODKOP_CONFIG" >/dev/null || fail 'mode switch must seed effective stable IDs and exclude disabled sources'
 [ "$peer_before" = "$(jq -c '.peer' "$PODKOP_CONFIG")" ] || fail 'selection leaked into another section'
 apply_subscription_exclusions_to_cached_links peer
 [ "$(cat "$SUBSCRIPTION_CACHE_DIR/peer.links")" = beta ] || fail 'identical source in peer section lost its independent selection'
 [ "$(cat "$SUBSCRIPTION_CACHE_DIR/main.links")" = alpha ] || fail 'unexpected runtime selection'
 [ "$(wc -l < "$work/commits")" -eq 1 ] || fail 'mode and toggles must commit once'
 # Newly published nodes stay off and identity changes preserve the chosen node.
 d="$(get_subscription_link_id delta)"
 jq --arg d "$d" --arg one "$one" '.+[ {id:$d,supported:true,sourceIds:[$one]} ]' "$SUBSCRIPTION_CACHE_DIR/main.items" > "$work/items"; mv "$work/items" "$SUBSCRIPTION_CACHE_DIR/main.items"
 printf '%s\n' delta >> "$SUBSCRIPTION_CACHE_DIR/main.all"
 apply_subscription_exclusions_to_cached_links main
 [ "$(cat "$SUBSCRIPTION_CACHE_DIR/main.links")" = alpha ] || fail 'new nodes must remain unselected'
 # Selecting a disabled-source node persists its preference without routing it.
 payload="$(jq -cn --arg c "$c" '{sections:[{section:"main",changes:[{id:$c,enabled:true}]}]}')"
 set_subscription_sections_enabled "$payload" | jq -e '.success' >/dev/null
 jq -e --arg c "$c" 'any(.[]; .id==$c and .enabled and (.runtimeEnabled|not))' "$SUBSCRIPTION_CACHE_DIR/main.items" >/dev/null
 before="$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links")"
 payload="$(jq -cn --arg a "$a" '{sections:[{section:"main",changes:[{id:$a,enabled:false}]}]}')"
 result="$(set_subscription_sections_enabled "$payload" || true)"
 printf '%s' "$result" | jq -e '.success==false and .error=="cannot_disable_last_enabled_link" and .committed==false' >/dev/null
 [ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links")" ] || fail 'empty effective selection mutated config'
 # Legacy toggle must add to the allowlist, not change the blacklist.
 set_subscription_links_enabled main "$b" 1 | jq -e '.success' >/dev/null
 jq -e --arg b "$b" '.main.subscription_selected_link_ids|index($b)!=null' "$PODKOP_CONFIG" >/dev/null
 # Mode-only transaction, invalid mode, rollback and all-mode reversion.
 before="$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links" "$SUBSCRIPTION_CACHE_DIR/main.items")"
 : > "$work/fail-reload"
 result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"all","changes":[]}]}' || true)"
 printf '%s' "$result" | jq -e '.state=="rolled_back" and .rolledBack' >/dev/null || fail 'mode failure must roll back'
 [ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links" "$SUBSCRIPTION_CACHE_DIR/main.items")" ] || fail 'mode rollback mismatch'
 result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"invalid","changes":[]}]}' || true)"
 printf '%s' "$result" | jq -e '.phase=="validation" and .error=="invalid_payload"' >/dev/null
 set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"all","changes":[]}]}' | jq -e '.success' >/dev/null
 jq -e '.main.subscription_selection_mode=="all"' "$PODKOP_CONFIG" >/dev/null
 [ "$(cat "$SUBSCRIPTION_CACHE_DIR/main.links")" = "$(printf 'alpha\nbeta\ndelta')" ] || fail 'all mode must restore normal blacklist policy'
 # Tag-only edits share the transaction; filters never erase individual choices.
 jq --arg a "$a" --arg b "$b" --arg c "$c" --arg d "$d" 'map(.name=(if .id==$a then "🇷🇺 Москва 1" elif .id==$b then "US West" elif .id==$c then "🇷🇺 Москва 2" elif .id==$d then "US East" else .name end))' "$SUBSCRIPTION_CACHE_DIR/main.items" > "$work/items"; mv "$work/items" "$SUBSCRIPTION_CACHE_DIR/main.items"
 before="$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/main.links")"
 result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","includeTags":["NO MATCH"],"changes":[]}]} ' || true)"
 printf '%s' "$result" | jq -e '.error=="cannot_disable_last_enabled_link" and .committed==false' >/dev/null || fail 'empty tag pool must be guarded'
 [ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/main.links")" ] || fail 'empty tag pool changed state'
 payload='{"sections":[{"section":"main","includeTags":["🇷🇺 Москва ?"],"excludeTags":["*2"],"changes":[]}]}'
 result="$(set_subscription_sections_enabled "$payload")"
 printf '%s' "$result" | jq -e '.success and .changed==2' >/dev/null || fail 'tag lists did not commit together'
 jq -e '.main.subscription_include_tags==["🇷🇺 Москва ?"] and .main.subscription_exclude_tags==["*2"]' "$PODKOP_CONFIG" >/dev/null || fail 'tag values with spaces were not persisted'
 [ "$(cat "$SUBSCRIPTION_CACHE_DIR/main.links")" = alpha ] || fail 'tag policy did not gate runtime links'
 jq -e --arg b "$b" 'any(.[]; .id==$b and .enabled and .tagExcluded and .reason=="tag_filtered")' "$SUBSCRIPTION_CACHE_DIR/main.items" >/dev/null || fail 'excluded node lost individual choice or visibility'
 [ "$peer_before" = "$(jq -c '.peer' "$PODKOP_CONFIG")" ] || fail 'tag policy leaked to peer section'
 before="$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/main.links")"
 : > "$work/fail-reload"
 result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","excludeTags":["US*"],"changes":[]}]} ' || true)"
 printf '%s' "$result" | jq -e '.state=="rolled_back" and .rolledBack' >/dev/null || fail 'tag reload failure must roll back'
 [ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/main.links")" ] || fail 'tag rollback mismatch'
 result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","includeTags":["bad\nnewline"],"changes":[]}]} ' || true)"
 printf '%s' "$result" | jq -e '.phase=="validation" and .error=="invalid_payload"' >/dev/null || fail 'newline tag must be rejected'
 # Turning manual selection off must be atomic and preserve choices for resuming.
 choices="$(jq -c '.main | {selected:.subscription_selected_link_ids,excluded:.subscription_excluded_link_ids}' "$PODKOP_CONFIG")"
 before="$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/main.links")"
 : > "$work/fail-reload"
 result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"auto","changes":[]}]}' || true)"
 printf '%s' "$result" | jq -e '.state=="rolled_back" and .rolledBack' >/dev/null || fail 'auto transition failure must roll back'
 [ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.items" "$SUBSCRIPTION_CACHE_DIR/main.links")" ] || fail 'auto rollback mismatch'
 set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"auto","changes":[]}]}' | jq -e '.success and .committed' >/dev/null
 [ "$choices" = "$(jq -c '.main | {selected:.subscription_selected_link_ids,excluded:.subscription_excluded_link_ids}' "$PODKOP_CONFIG")" ] || fail 'auto transition erased manual node choices'
 [ "$(cat "$SUBSCRIPTION_CACHE_DIR/main.links")" = alpha ] || fail 'auto must still honor source and tag gates'
 set_subscription_sections_enabled '{"sections":[{"section":"main","selectionMode":"selected","changes":[]}]}' | jq -e '.success and .committed' >/dev/null
 [ "$choices" = "$(jq -c '.main | {selected:.subscription_selected_link_ids,excluded:.subscription_excluded_link_ids}' "$PODKOP_CONFIG")" ] || fail 'auto-to-selected did not resume saved choices'
 rm -f "$work/commits" "$work/reloads"
done
# Required-service storage failure exercises the full real transaction plus
# real seamless reload and snapshot writer, with only UCI/process/disk fixtures.
. "$repo/openwrt/podkop-service-checks.sh"
. "$repo/openwrt/podkop-service-snapshot.sh"
sed -n '/^subscription_reload_seamless() {$/,/^}$/p' "$runtime" > "$work/seamless"
. "$work/seamless"
PODKOP_SERVICE_CACHE_DIR="$work/service-checks"
PODKOP_SERVICE_SNAPSHOT_DIR="$work/service-snapshot"
TMP_RULESET_FOLDER="$work/rules"
mkdir -p "$TMP_RULESET_FOLDER" "$work/bin"
cp "$repo/tests/fixtures/subscription_services_process.sh" "$work/bin/sing-box"; chmod 755 "$work/bin/sing-box"
PATH="$work/bin:$PATH"; export PATH
cfg="$work/sing-box.json"
printf '{"outbounds":[{"tag":"old"}],"route":{"rule_set":[]}}\n' > "$cfg"
cp "$cfg" "$work/old-cfg"
jq --arg cfg "$cfg" '.settings={config_path:$cfg}' "$PODKOP_CONFIG" > "$PODKOP_CONFIG.next"; mv "$PODKOP_CONFIG.next" "$PODKOP_CONFIG"
subscription_services_context() { printf 'transaction-context\n'; }
subscription_services_store main "$a" '{"gemini":{"state":"pass","network":"pass","manual":false,"reason":"region_precheck_passed"}}'
config_foreach() { "$1" main; "$1" peer; }
collect_urltest_proxy_links() { return 1; }
log() { :; }
subscription_services_snapshot_capacity() { return 1; }
before="$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links" "$SUBSCRIPTION_CACHE_DIR/main.items" "$cfg")"
result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","changes":[],"requiredServices":["gemini"]}]}' || true)"
printf '%s' "$result" | jq -e '.success==false and .committed==false and .error=="service_snapshot_storage_unavailable"' >/dev/null || fail 'storage preflight did not reject real transaction'
[ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links" "$SUBSCRIPTION_CACHE_DIR/main.items" "$cfg")" ] || fail 'low storage preflight changed config/cache/runtime'
subscription_services_snapshot_capacity() { return 0; }
eval "$(sed -n '/^ uci() {$/,/^ }$/p' "$0" | sed 's/^ //;1s/uci()/service_test_uci()/')"
uci() { [ "$1" != -q ] || shift; if [ "$1" = export ]; then cat "$PODKOP_CONFIG"; else service_test_uci "$@"; fi; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 100 100 0 100%% /\n'; }
sing_box_init_config() {
    if [ "$(subscription_required_services_json main)" != '[]' ]; then
        printf '{"outbounds":[{"tag":"candidate"}],"route":{"rule_set":[]}}\n' > "$cfg"
    else cp "$work/old-cfg" "$cfg"; fi
}
subscription_sing_box_pid() { printf '123\n'; }
subscription_signal_sing_box_reload() { printf 'signal\n' >> "$work/service-signals"; }
subscription_sing_box_reload_ready() { return 0; }
subscription_apply_v2_reload() { PODKOP_SUBSCRIPTION_APPLY_NOW=1 PODKOP_SUBSCRIPTION_RELOAD_DELAY=0 subscription_reload_seamless; }
result="$(set_subscription_sections_enabled '{"sections":[{"section":"main","changes":[],"requiredServices":["gemini"]}]}' || true)"
printf '%s' "$result" | jq -e '.success==false and .state=="rolled_back" and .rolledBack' >/dev/null || fail 'snapshot save failure did not roll back real transaction'
[ "$before" = "$(sha256sum "$PODKOP_CONFIG" "$SUBSCRIPTION_CACHE_DIR/main.links" "$SUBSCRIPTION_CACHE_DIR/main.items" "$cfg")" ] || fail 'late snapshot failure failed to restore UCI/cache/full config'
[ "$(wc -l < "$work/service-signals")" -eq 2 ] || fail 'late snapshot failure did not signal candidate then previous runtime'
[ ! -f "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json" ] || fail 'failed activation saved a snapshot'
echo 'PASS: full required-service transaction rejects low storage and rolls back UCI/cache/config after late snapshot failure'
# Existing installations need the complete policy, transaction and legacy toggle retrofit.
for version in 0.7.20 0.7.22; do
 runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
 sed '/^# subscription_tag_glob_portable_v1$/d' "$runtime" > "$work/delivery"
 PODKOP_SOURCES_TARGET="$work/delivery" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
 grep -Fqx '# subscription_tag_glob_portable_v1' "$work/delivery" || fail 'existing modern runtime skipped portable-glob upgrade'
 for name in set_subscription_links_enabled set_subscription_sections_enabled apply_subscription_exclusions_to_cached_links refresh_subscription_cache; do
   sed -n "/^$name() {$/,/^}$/p" "$work/delivery" > "$work/delivered.function"
   sed -n "/^$name() {$/,/^}$/p" "$runtime" > "$work/canonical.function"
   cmp -s "$work/delivered.function" "$work/canonical.function" || fail "allowlist retrofit has stale $name"
 done
 sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$work/delivery" > "$work/delivered.sources"
 cmp -s "$work/delivered.sources" "$repo/openwrt/podkop-subscription-sources.sh" || fail 'allowlist retrofit has stale source policy'
 sh -n "$work/delivery"
 cp "$work/delivery" "$work/delivered"
 PODKOP_SOURCES_TARGET="$work/delivery" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
 cmp -s "$work/delivery" "$work/delivered" || fail 'allowlist retrofit is not idempotent'
done
echo 'PASS: per-section allowlist policy, atomic migration/toggles, default-off new nodes, source independence, guard, legacy toggle, and rollback'
