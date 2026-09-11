#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo_root/openwrt/runtime-0.7.22/usr/bin/podkop"
upgrade="$repo_root/openwrt/podkop-subscription-seamless-reload-upgrade.sh"
installer="$repo_root/i"
test_root="$(mktemp -d)"
fixture="$test_root/podkop"
backup="$test_root/podkop.backup"

cleanup() {
	rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

fail_test() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ -f "$upgrade" ] || fail_test 'seamless reload delivery upgrade is missing'

awk '
$0 == "# subscription_seamless_reload begin" { skipping = 1; next }
skipping && $0 == "# subscription_seamless_reload end" { skipping = 0; next }
skipping { next }
{ print }
' "$runtime" |
	sed 's#        subscription_reload_seamless#        PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload#' \
		> "$fixture"
sed -i '1c\#!/bin/sh' "$fixture"
sed -i '1a\[ "$1" = show_version ] && { echo 0.7.22; exit 0; }' "$fixture"
chmod 755 "$fixture"

PODKOP_SUBSCRIPTION_SEAMLESS_TARGET="$fixture" \
	PODKOP_SUBSCRIPTION_SEAMLESS_SOURCE="$runtime" \
	PODKOP_SUBSCRIPTION_SEAMLESS_BACKUP="$backup" \
	sh "$upgrade" >/dev/null

[ "$(grep -Fxc '# subscription_seamless_reload begin' "$fixture")" -eq 1 ] ||
	fail_test 'upgrade did not install exactly one seamless reload block'
[ "$(grep -Fxc '# subscription_seamless_reload end' "$fixture")" -eq 1 ] ||
	fail_test 'upgrade installed an incomplete seamless reload block'
subscription_update_body="$(sed -n '/^subscription_update() {/,/^}/p' "$fixture")"
printf '%s\n' "$subscription_update_body" | grep -q 'subscription_reload_seamless' ||
	fail_test 'upgrade did not switch scheduled refresh to seamless activation'
if printf '%s\n' "$subscription_update_body" | grep -q '/usr/bin/podkop reload'; then
	fail_test 'upgrade left the disruptive full reload in scheduled refresh'
fi
[ -f "$backup" ] || fail_test 'upgrade did not back up the previous runtime'
sh -n "$fixture" || fail_test 'upgraded runtime has invalid shell syntax'

second_backup="$test_root/unexpected-second-backup"
PODKOP_SUBSCRIPTION_SEAMLESS_TARGET="$fixture" \
	PODKOP_SUBSCRIPTION_SEAMLESS_SOURCE="$runtime" \
	PODKOP_SUBSCRIPTION_SEAMLESS_BACKUP="$second_backup" \
	sh "$upgrade" >/dev/null
[ ! -e "$second_backup" ] || fail_test 'idempotent upgrade created a second backup'

# An already-delivered soft reload must also receive the new default policy.
sed -i '/subscription_deferred_apply_v1/d' "$fixture"
PODKOP_SUBSCRIPTION_SEAMLESS_TARGET="$fixture" \
	PODKOP_SUBSCRIPTION_SEAMLESS_SOURCE="$runtime" \
	PODKOP_SUBSCRIPTION_SEAMLESS_BACKUP="$second_backup" \
	sh "$upgrade" >/dev/null
grep -q 'subscription_deferred_apply_v1' "$fixture" || fail_test 'old soft reload was incorrectly treated as current'
[ -f "$second_backup" ] || fail_test 'old soft reload upgrade has no backup'

grep -q 'SEAMLESS_RELOAD_UPGRADE_FILE="podkop-subscription-seamless-reload-upgrade.sh"' "$installer" ||
	fail_test 'installer does not name the seamless reload upgrade asset'
grep -q 'download "$RAW_BASE/$SEAMLESS_RELOAD_UPGRADE_FILE"' "$installer" ||
	fail_test 'installer does not prefetch the seamless reload upgrade asset'
grep -q 'PODKOP_SUBSCRIPTION_SEAMLESS_SOURCE="$seamless_source"' "$installer" ||
	fail_test 'installer does not pass the canonical runtime to the seamless upgrade'
sed -n '/^has_latest_subscription_backend() {/,/^}/p' "$installer" |
	grep -q 'subscription_reload_seamless' ||
	fail_test 'installer no-op capability does not require seamless subscription activation'
sed -n '/^has_latest_subscription_backend() {/,/^}/p' "$installer" |
	grep -q 'subscription_reload_pending_file' ||
	fail_test 'installer no-op capability does not require deferred activation recovery'

printf '%s\n' 'PASS: existing routers receive seamless subscription refresh through the patch installer'
