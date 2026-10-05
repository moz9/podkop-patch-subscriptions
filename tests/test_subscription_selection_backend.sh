#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-subscription-sources.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
printf '%s\n' '[{"id":"current","selectionId":"stable","supported":true,"sourceIds":["s"]},{"id":"new","supported":true,"sourceIds":["s"]}]' > "$work/policy.items"
subscription_source_policy '[]' '[]' "$work/policy.items" selected '["stable"]' | jq -e '.[0].enabled and (.[1].enabled|not)' >/dev/null || fail 'selected mode must enable only stable selected identities'
subscription_source_policy '["s"]' '[]' "$work/policy.items" selected '["stable"]' | jq -e '.[0].enabled and (.[0].runtimeEnabled|not)' >/dev/null || fail 'disabled source must retain selected choice'
subscription_source_policy '[]' '["stable"]' "$work/policy.items" | jq -e '(.[0].enabled|not) and .[1].enabled' >/dev/null || fail 'default blacklist mode changed'
jq '.[0] += {name:"Node",protocol:"vless",connectionKey:"connection"}' "$work/policy.items" > "$work/identity.old"
jq '.[0] += {id:"rotated",name:"Renamed",protocol:"vless",connectionKey:"connection"}' "$work/policy.items" > "$work/identity.new"
subscription_reconcile_choices "$work/identity.old" "$work/identity.new" > "$work/identity.result"
subscription_source_policy '[]' '[]' "$work/identity.result" selected '["stable"]' | jq -e '.[0].selectionId=="stable" and .[0].enabled and (.[1].enabled|not)' >/dev/null || fail 'rotated identity lost its selected preference'

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
 rm -f "$work/commits" "$work/reloads"
done
# Existing installations need the complete policy, transaction and legacy toggle retrofit.
for version in 0.7.20 0.7.22; do
 runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
 sed '/^# subscription_selection_v1$/d' "$runtime" > "$work/delivery"
 PODKOP_SOURCES_TARGET="$work/delivery" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
 grep -Fqx '# subscription_selection_v1' "$work/delivery" || fail 'existing modern runtime skipped allowlist upgrade'
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
