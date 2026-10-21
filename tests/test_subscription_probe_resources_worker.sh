#!/bin/sh
# Exercise the actual worker lifecycle against private process fixtures.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$repo/openwrt/podkop-service-checks.sh"
. "$repo/openwrt/podkop-subscription-probe.sh"
PODKOP_SUBSCRIPTION_MEMINFO_FILE="$tmp/meminfo"
PODKOP_PROBE_STATUS_DIR="$tmp/status"
export PODKOP_SUBSCRIPTION_MEMINFO_FILE PODKOP_PROBE_STATUS_DIR
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { return 0; }
validate_subscription_link_id() { [ "$1" = "$id" ]; }
subscription_runtime_busy() { return 1; }
subscription_action_lock_acquire() { touch "$tmp/locked"; }
subscription_action_lock_release() { touch "$tmp/released"; }
get_subscription_items_cache_path() { printf '%s/items\n' "$tmp"; }
get_subscription_all_cache_path() { printf '%s/all\n' "$tmp"; }
get_subscription_link_id() { printf '%s\n' "$id"; }
podkop_section_logical_path() { printf '%s/config\n' "$tmp"; }
config_get() { eval "$1=''"; }
sing_box_cf_add_proxy_outbound() { printf '%s' "$1" | jq '.outbounds=[{type:"direct",tag:"candidate"}]'; }
get_outbound_tag_by_section() { printf 'candidate\n'; }
subscription_services_probe() { touch "$tmp/http"; printf '{}\n'; }
mkdir "$tmp/bin"
cp "$repo/tests/fixtures/subscription_services_process.sh" "$tmp/bin/sing-box"
chmod 755 "$tmp/bin/sing-box"
PATH="$tmp/bin:$PATH"
PODKOP_SERVICE_PROCESS_FIXTURE="$tmp"
export PATH PODKOP_SERVICE_PROCESS_FIXTURE
netstat() {
    if [ -f "$tmp/started" ]; then
        printf 'MemTotal: 131072 kB\nMemAvailable: 15000 kB\n' > "$tmp/meminfo"
        printf 'tcp 0 0 127.0.0.1:%s 0.0.0.0:* LISTEN\n' "$((43000 + $$ % 1000))"
    fi
}
printf '[{"id":"%s","supported":true,"name":"private"}]\n' "$id" > "$tmp/items"
printf 'opaque-link\n' > "$tmp/all"
printf '{"dns":{"servers":[{"tag":"real","type":"udp","server":"1.1.1.1"}],"final":"real"}}\n' > "$tmp/config"
printf 'MemTotal: 131072 kB\nMemAvailable: 15000 kB\n' > "$tmp/meminfo"
rc=0
subscription_isolated_test main "$id" services '["gemini"]' > "$tmp/result" || rc=$?
[ "$rc" = 1 ] || fail 'low RAM worker admitted'
jq -e '.success==false and .stage=="memory_admission" and .error=="insufficient_memory"' "$tmp/result" >/dev/null || fail 'RAM error not structured'
[ -f "$tmp/released" ] && [ ! -f "$tmp/started" ] || fail 'pre-build rejection cleanup failed'
printf 'MemTotal: 131072 kB\nMemAvailable: 65536 kB\n' > "$tmp/meminfo"
rc=0
subscription_isolated_test main "$id" services '["gemini"]' > "$tmp/result" || rc=$?
[ "$rc" = 1 ] && [ ! -f "$tmp/http" ] || fail 'memory pressure after listener startup still launched HTTP'
jq -e '.stage=="memory_admission" and .error=="insufficient_memory"' "$tmp/result" >/dev/null || fail 'runtime RAM error lost'
rm -f "$tmp/started"
netstat() { [ ! -f "$tmp/started" ] || printf 'tcp 0 0 127.0.0.1:%s 0.0.0.0:* LISTEN\n' "$((43000 + $$ % 1000))"; }
get_subscription_benchmark_bytes() { printf '1048576\n'; }
get_subscription_benchmark_streams() { printf '8\n'; }
get_subscription_benchmark_timeout() { printf '10\n'; }
curl() {
    last=''; for value in "$@"; do last="$value"; done
    touch "$tmp/request.${last##*probe=}"
    printf '200 1048576 2.0 0.0'
}
printf 'MemTotal: 131072 kB\nMemAvailable: 65536 kB\n' > "$tmp/meminfo"
subscription_isolated_test main "$id" speed > "$tmp/speed" || fail 'speed worker failed'
jq -e '.success==true and .results[0].success==true and .results[0].requestedStreams==8 and .results[0].streams==2 and .results[0].sizeDownload==2097152 and .results[0].bytesPerSecond==1048576' "$tmp/speed" >/dev/null || fail 'effective concurrent speed calculation changed'
[ "$(find "$tmp" -name 'request.*' | wc -l)" = 2 ] || fail 'speed worker launched more than two streams'
echo 'PASS: worker RAM failures retain diagnostic identity, release lock and refuse HTTP under pressure'
