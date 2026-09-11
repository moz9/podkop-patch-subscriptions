#!/bin/sh
set -eu

target="${PODKOP_SUBSCRIPTION_SEAMLESS_TARGET:-/usr/bin/podkop}"
source_runtime="${PODKOP_SUBSCRIPTION_SEAMLESS_SOURCE:-}"
patch_version="${PODKOP_PATCH_VERSION:-main}"
raw_base="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$patch_version/openwrt}"
tmp_dir="$(mktemp -d /tmp/podkop-subscription-seamless-upgrade.XXXXXX)"
staged_target="${target}.subscription-seamless.$$"

cleanup() {
	rm -rf "$tmp_dir"
	rm -f "$staged_target"
}
trap cleanup EXIT INT TERM HUP

fail() {
	printf 'Subscription seamless reload upgrade failed: %s\n' "$1" >&2
	exit 1
}

download_source_runtime() {
	local url="$raw_base/runtime-0.7.20/usr/bin/podkop"
	local output="$tmp_dir/source-runtime"

	if command -v curl >/dev/null 2>&1 &&
		curl -fsSL --connect-timeout 10 -m 45 -o "$output" "$url"; then
		source_runtime="$output"
		return 0
	fi
	if command -v wget >/dev/null 2>&1 &&
		wget --no-check-certificate -T 45 -O "$output" "$url"; then
		source_runtime="$output"
		return 0
	fi
	return 1
}

[ -f "$target" ] || fail "runtime not found at $target"
grep -q '^subscription_update() {' "$target" || fail 'subscription update backend is not installed'

version="$($target show_version 2>/dev/null | sed 's/^v//' | head -n 1 || true)"
case "$version" in
0.7.19 | 0.7.20 | 0.7.21 | 0.7.22) ;;
*) fail "unsupported Podkop version: ${version:-unknown}" ;;
esac

if grep -Fqx '# subscription_seamless_reload begin' "$target" &&
	grep -q 'subscription_deferred_apply_v1' "$target" &&
	grep -Fqx '# subscription_seamless_reload end' "$target" &&
	sed -n '/^subscription_update() {/,/^}/p' "$target" | grep -q 'subscription_reload_seamless' &&
	! sed -n '/^subscription_update() {/,/^}/p' "$target" | grep -q '/usr/bin/podkop reload'; then
	printf '%s\n' 'Subscription seamless reload is already installed.'
	exit 0
fi

if [ -z "$source_runtime" ]; then
	download_source_runtime || fail 'unable to download canonical seamless runtime source'
fi
[ -f "$source_runtime" ] || fail "canonical runtime source not found at $source_runtime"
grep -Fqx '# subscription_seamless_reload begin' "$source_runtime" || fail 'canonical seamless block start marker is missing'
grep -Fqx '# subscription_seamless_reload end' "$source_runtime" || fail 'canonical seamless block end marker is missing'
sh -n "$source_runtime" || fail 'canonical runtime source has invalid shell syntax'

sed -n '/^# subscription_seamless_reload begin$/,/^# subscription_seamless_reload end$/p' \
	"$source_runtime" > "$tmp_dir/seamless.block"
[ -s "$tmp_dir/seamless.block" ] || fail 'canonical seamless block is empty'

awk '
$0 == "# subscription_seamless_reload begin" { skipping = 1; next }
skipping && $0 == "# subscription_seamless_reload end" { skipping = 0; next }
skipping { next }
{ print }
' "$target" > "$tmp_dir/runtime.clean"

awk -v block="$tmp_dir/seamless.block" '
BEGIN { inserted = 0; in_update = 0; switched = 0 }
!inserted && $0 == "subscription_update_section_handler() {" {
	while ((getline line < block) > 0) print line
	close(block)
	print ""
	inserted = 1
}
$0 == "subscription_update() {" { in_update = 1 }
in_update && $0 ~ /^[[:space:]]*subscription_reload_seamless$/ { switched = 1 }
in_update && $0 ~ /^[[:space:]]*echolog "Subscription cache changed, reloading podkop\.\.\."$/ {
	print "        echolog \"Subscription cache changed, activating it without rebuilding the network...\""
	next
}
in_update && $0 ~ /^[[:space:]]*PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 \/usr\/bin\/podkop reload$/ {
	print "        subscription_reload_seamless"
	switched = 1
	next
}
{ print }
in_update && $0 == "}" { in_update = 0 }
END { if (!inserted || !switched) exit 42 }
' "$tmp_dir/runtime.clean" > "$tmp_dir/runtime.final" || fail 'unable to install seamless subscription activation'

[ "$(grep -Fxc '# subscription_seamless_reload begin' "$tmp_dir/runtime.final")" -eq 1 ] || fail 'seamless block verification failed'
[ "$(grep -Fxc '# subscription_seamless_reload end' "$tmp_dir/runtime.final")" -eq 1 ] || fail 'seamless block end verification failed'
sed -n '/^subscription_update() {/,/^}/p' "$tmp_dir/runtime.final" | grep -q 'subscription_reload_seamless' ||
	fail 'scheduled refresh verification failed'
if sed -n '/^subscription_update() {/,/^}/p' "$tmp_dir/runtime.final" | grep -q '/usr/bin/podkop reload'; then
	fail 'disruptive scheduled reload remains after upgrade'
fi
sh -n "$tmp_dir/runtime.final" || fail 'upgraded runtime has invalid shell syntax'

backup="${PODKOP_SUBSCRIPTION_SEAMLESS_BACKUP:-/root/podkop-subscription-seamless-backup-$(date +%Y%m%d-%H%M%S)-$$}"
cp -p "$target" "$backup" || fail 'unable to back up current runtime'
cp "$tmp_dir/runtime.final" "$staged_target" || fail 'unable to stage upgraded runtime'
chmod 755 "$staged_target" || fail 'unable to set runtime permissions'
mv "$staged_target" "$target" || fail 'unable to atomically install upgraded runtime'

printf 'Installed seamless subscription reload. Backup: %s\n' "$backup"
