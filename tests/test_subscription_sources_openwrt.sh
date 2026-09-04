#!/bin/sh
# Runs the real UCI transaction against private copies, never the live config.
set -e
runtime="${1:?staged runtime required}"
test_work="$(mktemp -d /tmp/podkop-sources-contract.XXXXXX)"
umask 077
mkdir "$test_work/config" "$test_work/uci" "$test_work/cache"
cp /etc/config/podkop "$test_work/config/podkop"
cp -a /etc/podkop/subscriptions/. "$test_work/cache/"
sed '/^case "\$1" in/,$d' "$runtime" > "$test_work/library"
set +e
. "$test_work/library"
set -e
PODKOP_CONFIG="$test_work/config/podkop"
SUBSCRIPTION_CACHE_DIR="$test_work/cache"
UCI_CONFIG_DIR="$test_work/config"
export UCI_CONFIG_DIR
uci() { /sbin/uci -c "$test_work/config" -t "$test_work/uci" "$@"; }
config_load() { uci_load podkop; }
subscription_apply_v2_reload() {
    printf 'reload\n' >> "$test_work/reloads"
    if [ -f "$test_work/fail-next-reload" ]; then rm -f "$test_work/fail-next-reload"; return 1; fi
}
uci -q delete podkop.main.subscription_disabled_source_ids || true
uci commit podkop
config_load podkop || { echo 'FAIL: sandbox config load'; exit 1; }
live_hash="$(sha256sum /etc/config/podkop /etc/sing-box/config.json)"
live_pid="$(pidof sing-box)"
sources="$(get_subscription_sources main)"
source1="$(printf '%s' "$sources" | jq -r '.[0].id')"
source2="$(printf '%s' "$sources" | jq -r '.[1].id')"
items="$(get_subscription_items_cache_path main)"
first="$(jq -r '[.[] | select(.supported and .sourceIndex == 1)][0].id' "$items")"
payload="$(jq -cn --arg source "$source1" --arg id "$first" '{sections:[{section:"main",changes:[{id:$id,enabled:false}],sources:[{id:$source,enabled:false}]}]}')"
result="$(set_subscription_sections_enabled "$payload" || true)"
printf '%s' "$result" | jq -e '.success and .changed == 2 and .committed' >/dev/null || { printf '%s\n' "$result"; exit 1; }
jq -e '[.[] | select(.sourceIndex == 1 and .runtimeEnabled)] | length == 0' "$items" >/dev/null
jq -e --arg id "$first" 'any(.[]; .id == $id and .enabled == false)' "$items" >/dev/null
[ "$(wc -l < "$test_work/reloads")" -eq 1 ]
printf 'PASS: mixed config/source transaction commits and activates once\n'
config_load podkop
# Disabling the final usable source is rejected, with no extra commit/reload.
payload="$(jq -cn --arg id "$source2" '{sections:[{section:"main",changes:[],sources:[{id:$id,enabled:false}]}]}')"
result="$(set_subscription_sections_enabled "$payload" || true)"
printf '%s' "$result" | jq -e '.success == false and .error == "cannot_disable_last_enabled_link" and .committed == false' >/dev/null
[ "$(wc -l < "$test_work/reloads")" -eq 1 ]
printf 'PASS: last source guard leaves previous config intact\n'
subscription_ping main "$first" | jq -e '.success and .latencyMs > 0' >/dev/null
PODKOP_SUBSCRIPTION_BENCHMARK_BYTES=262144 PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS=1 PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT=8 \
    subscription_speedtest main "$first" | jq -e '.success and .results[0].success and .results[0].bytesPerSecond > 0' >/dev/null
printf 'PASS: excluded config in disabled subscription supports isolated ping and benchmark\n'
payload="$(jq -cn --arg id "$source1" '{sections:[{section:"main",changes:[],sources:[{id:$id,enabled:true}]}]}')"
before_failure="$(sha256sum "$PODKOP_CONFIG" "$items" "$(get_subscription_cache_path main)")"
touch "$test_work/fail-next-reload"
result="$(set_subscription_sections_enabled "$payload" || true)"
printf '%s' "$result" | jq -e '.success == false and .state == "rolled_back" and .rolledBack' >/dev/null
[ "$before_failure" = "$(sha256sum "$PODKOP_CONFIG" "$items" "$(get_subscription_cache_path main)")" ]
printf 'PASS: failed activation restores both source/config preferences and caches\n'
config_load podkop
set_subscription_sections_enabled "$payload" | jq -e '.success' >/dev/null
jq -e --arg id "$first" 'any(.[]; .id == $id and .enabled == false and .runtimeEnabled == false)' "$items" >/dev/null
[ "$live_hash" = "$(sha256sum /etc/config/podkop /etc/sing-box/config.json)" ]
[ "$live_pid" = "$(pidof sing-box)" ]
printf 'PASS: re-enabling source preserves config preferences; live router unchanged\n'
payload="$(jq -cn --arg id "$source1" '{sections:[{section:"main",changes:[],sources:[{id:$id,enabled:false}]}]}')"
config_load podkop
set_subscription_sections_enabled "$payload" | jq -e '.success' >/dev/null
config_load podkop
refresh_subscription_cache main >/dev/null
jq -e '[.[] | select(.sourceIndex == 1 and .runtimeEnabled)] | length == 0' "$items" >/dev/null
jq -e --arg id "$source1" 'any(.[]; (.sourceIds | index($id)) != null)' "$items" >/dev/null
printf 'PASS: downloaded subscriptions retain source identity and disabled traffic policy\n'
rm -rf "$test_work"
