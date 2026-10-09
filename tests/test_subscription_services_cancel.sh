#!/bin/sh
# Exercise the real isolated worker against private process/HTTP fixtures.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
worker=''
trap '[ -z "$worker" ] || kill "$worker" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$repo/openwrt/podkop-subscription-sources.sh"
. "$repo/openwrt/podkop-service-checks.sh"
. "$repo/openwrt/podkop-subscription-probe.sh"
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '[{"id":"%s","supported":true,"name":"private fixture"}]\n' "$id" > "$tmp/items"
printf 'opaque-private-link\n' > "$tmp/all"
printf '{"dns":{"servers":[{"type":"udp","tag":"dns","server":"1.1.1.1"}],"final":"dns"},"route":{"default_domain_resolver":"dns"}}\n' > "$tmp/config"
before="$(sha256sum "$tmp/items" "$tmp/all" "$tmp/config")"
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { [ "$1" = main ]; }
validate_subscription_link_id() { [ "$1" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]; }
subscription_runtime_busy() { return 1; }
subscription_action_lock_acquire() { touch "$tmp/locked"; }
subscription_action_lock_release() { touch "$tmp/released"; }
get_subscription_items_cache_path() { printf '%s/items\n' "$tmp"; }
get_subscription_all_cache_path() { printf '%s/all\n' "$tmp"; }
get_subscription_link_id() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
config_get() { eval "$1=''"; }
sing_box_cf_add_proxy_outbound() { printf '%s\n' "$1"; }
get_outbound_tag_by_section() { printf 'private-test\n'; }
jq() {
    last=''; for value in "$@"; do last="$value"; done
    if [ "$last" = /etc/sing-box/config.json ]; then
        command jq "$1" "$2" "$tmp/config"
    else command jq "$@"; fi
}
netstat() { [ ! -f "$tmp/started" ] || printf 'tcp 0 0 127.0.0.1:%s 0.0.0.0:* LISTEN\n' "$((43000 + $$ % 1000))"; }
mkdir "$tmp/bin"
cp "$repo/tests/fixtures/subscription_services_process.sh" "$tmp/bin/sing-box"
cp "$repo/tests/fixtures/subscription_services_process.sh" "$tmp/bin/curl"
chmod 755 "$tmp/bin/sing-box" "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"
PODKOP_SERVICE_PROCESS_FIXTURE="$tmp"
export PATH PODKOP_SERVICE_PROCESS_FIXTURE
subscription_isolated_test main "$id" services '["gemini"]' > "$tmp/result" &
worker=$!
tries=0
while [ ! -f "$tmp/curl-started" ]; do
    kill -0 "$worker" 2>/dev/null || fail "worker did not reach HTTP fixture: $(cat "$tmp/result")"
    [ "$tries" -lt 40 ] || fail 'worker startup timed out'
    sleep 0.1; tries=$((tries + 1))
done
kill "$worker"
wait "$worker" 2>/dev/null || :
worker=''
[ -f "$tmp/released" ] || fail 'cancel did not release action lock'
for pidfile in "$tmp/probe.pid" "$tmp/curl.pid"; do
    child="$(cat "$pidfile")"
    ! kill -0 "$child" 2>/dev/null || fail 'cancel left an isolated child running'
done
[ "$before" = "$(sha256sum "$tmp/items" "$tmp/all" "$tmp/config")" ] || fail 'cancel mutated production substitutes'
echo 'PASS: real isolated worker cancellation releases action lock and preserves inputs'
