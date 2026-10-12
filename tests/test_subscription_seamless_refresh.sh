#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo_root/openwrt/runtime-0.7.22/usr/bin/podkop"
test_root="$(mktemp -d)"
block="$test_root/seamless.block"

cleanup() {
	rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

fail_test() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -Fqx '# subscription_seamless_reload begin' "$runtime" ||
	fail_test 'runtime does not contain the seamless subscription reload capability'
grep -Fqx '# subscription_seamless_reload end' "$runtime" ||
	fail_test 'runtime contains an incomplete seamless subscription reload capability'

sed -n '/^# subscription_seamless_reload begin$/,/^# subscription_seamless_reload end$/p' \
	"$runtime" > "$block"

# shellcheck disable=SC1090
. "$block"

TEST_CONFIG_PATH="$test_root/config.json"
printf '%s\n' old-config > "$TEST_CONFIG_PATH"

config_get() {
	eval "$1=\$TEST_CONFIG_PATH"
}
log() {
	:
}
sing_box_init_config() {
	printf '%s\n' new-config > "$TEST_CONFIG_PATH"
}
subscription_sing_box_pid() {
	printf '%s\n' 1234
}
signal_count=0
subscription_signal_sing_box_reload() {
	signal_count=$((signal_count + 1))
}
subscription_sing_box_reload_ready() {
	return 0
}
PODKOP_SUBSCRIPTION_RELOAD_ATTEMPTS=1
PODKOP_SUBSCRIPTION_APPLY_NOW=1
PODKOP_SUBSCRIPTION_RELOAD_DELAY=0
PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE="$test_root/reload.pending"
export PODKOP_SUBSCRIPTION_RELOAD_ATTEMPTS PODKOP_SUBSCRIPTION_RELOAD_DELAY PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE

subscription_reload_seamless ||
	fail_test 'changed subscription config did not activate successfully'
[ "$(cat "$TEST_CONFIG_PATH")" = new-config ] ||
	fail_test 'changed subscription config was not kept after successful activation'
[ "$signal_count" -eq 1 ] ||
	fail_test "changed subscription config sent $signal_count reload signals instead of 1"
[ ! -e "$PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE" ] ||
	fail_test 'successful activation left a stale pending-reload marker'

signal_count=0
sing_box_init_config() {
	:
}
subscription_reload_seamless ||
	fail_test 'unchanged subscription config was treated as an error'
[ "$signal_count" -eq 0 ] ||
	fail_test 'unchanged subscription config unnecessarily reloaded sing-box'

printf '%s\n' stable-config > "$TEST_CONFIG_PATH"
signal_count=0
sing_box_init_config() {
	printf '%s\n' broken-runtime-config > "$TEST_CONFIG_PATH"
}
subscription_sing_box_reload_ready() {
	return 1
}
if subscription_reload_seamless; then
	fail_test 'failed hot reload was reported as successful'
fi
[ "$(cat "$TEST_CONFIG_PATH")" = stable-config ] ||
	fail_test 'failed hot reload did not restore the previous sing-box config'
[ "$signal_count" -eq 2 ] ||
	fail_test "failed hot reload sent $signal_count signals instead of activation plus recovery"
[ -f "$PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE" ] ||
	fail_test 'failed activation was not preserved for the next scheduled retry'

signal_count=0
subscription_sing_box_reload_ready() {
	return 0
}
subscription_reload_seamless ||
	fail_test 'a pending activation did not recover on the next attempt'
[ "$signal_count" -eq 1 ] ||
	fail_test "pending activation sent $signal_count reload signals instead of 1"
[ ! -e "$PODKOP_SUBSCRIPTION_RELOAD_PENDING_FILE" ] ||
	fail_test 'recovered activation did not clear its pending marker'

subscription_update_body="$(sed -n '/^subscription_update() {/,/^}/p' "$runtime")"
printf '%s\n' "$subscription_update_body" | grep -q 'subscription_reload_seamless' ||
	fail_test 'scheduled subscription update does not use seamless activation'
printf '%s\n' "$subscription_update_body" | grep -q 'subscription_reload_pending' ||
	fail_test 'scheduled subscription update does not retry a previously failed activation'
if printf '%s\n' "$subscription_update_body" | grep -q '/usr/bin/podkop reload'; then
	fail_test 'scheduled subscription update still performs a disruptive full Podkop reload'
fi

printf '%s\n' 'PASS: subscription refresh keeps nft and dnsmasq online while activating new proxies'
