#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-v2026.06.16-subscriptions-apply-fix}"
RAW_BASE="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PATCH_VERSION/openwrt}"
BACKUPS_KEEP="${PODKOP_PATCH_BACKUPS_KEEP:-2}"
PATCH_FILE="podkop-subscription-urltest-runtime.patch"
V0719_PATCH_FILE="podkop-subscription-v0719-runtime.patch"
CACHE_ONLY_UPGRADE_PATCH_FILE="podkop-subscription-cache-only-upgrade.patch"
ACTIONS_UPGRADE_PATCH_FILE="podkop-subscription-actions-upgrade.patch"
LEGACY_UPGRADE_PATCH_FILE="podkop-subscription-legacy-upgrade.patch"
UI_FIX_BACKEND_FILE="podkop-actions-ui-fix.sh"
MAIN_JS_FILE="main.js"
LMO_FILE="podkop.ru.lmo.base64"
SUBSCRIPTIONS_FILE="subscriptions.js"

RUNTIME_FILES="
usr/bin/podkop
usr/lib/podkop/sing_box_config_facade.sh
www/luci-static/resources/view/podkop/main.js
www/luci-static/resources/view/podkop/podkop.js
www/luci-static/resources/view/podkop/section.js
www/luci-static/resources/view/podkop/subscriptions.js
usr/lib/lua/luci/i18n/podkop.ru.lmo
"

log() {
	printf '%s\n' "$*"
}

fail() {
	log "ERROR: $*"
	exit 1
}

download() {
	url="$1"
	out="$2"

	case "$url" in
		*raw.githubusercontent.com*)
			url="$url?podkop_patch=$(date +%s)"
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$out"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		fail "curl or wget is required"
	fi
}

require_patch() {
	if command -v patch >/dev/null 2>&1; then
		return 0
	fi

	if command -v opkg >/dev/null 2>&1; then
		log "Installing patch utility..."
		opkg update >/dev/null 2>&1 || true
		opkg install patch >/dev/null 2>&1 || true
	fi

	command -v patch >/dev/null 2>&1 || fail "patch utility is required"
}

get_path_size() {
	path="$1"

	if command -v du >/dev/null 2>&1; then
		du -sh "$path" 2>/dev/null | awk '{print $1}'
	else
		echo "unknown"
	fi
}

cleanup_old_backups() {
	keep="$BACKUPS_KEEP"
	count=0

	case "$keep" in
		"" | *[!0-9]*)
			keep=2
			;;
	esac

	if [ "$keep" -lt 1 ]; then
		keep=1
	fi

	for dir in $(ls -1dt /root/podkop-patch-subscriptions-backup-* 2>/dev/null); do
		[ -d "$dir" ] || continue
		count=$((count + 1))
		if [ "$count" -gt "$keep" ]; then
			rm -rf "$dir"
			log "Removed old backup: $dir"
		fi
	done

	log "Keeping last $keep backup(s)."
}

backup_runtime() {
	backup_dir="/root/podkop-patch-subscriptions-backup-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$backup_dir"

	for rel in $RUNTIME_FILES; do
		src="/$rel"
		if [ -e "$src" ]; then
			mkdir -p "$backup_dir/$(dirname "$rel")"
			cp -a "$src" "$backup_dir/$rel"
		fi
	done

	log "Backup: $backup_dir"
	log "Backup size: $(get_path_size "$backup_dir")"
}

restore_runtime() {
	log "Restoring backup..."
	for rel in $RUNTIME_FILES; do
		dst="/$rel"
		src="$backup_dir/$rel"
		if [ -e "$src" ]; then
			mkdir -p "$(dirname "$dst")"
			cp -a "$src" "$dst"
		else
			rm -f "$dst"
		fi
	done
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
	[ -x /etc/init.d/podkop ] && /etc/init.d/podkop reload >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

abort_with_restore() {
	restore_runtime
	fail "$1"
}

has_latest_subscription_backend() {
	grep -q "PODKOP_SUBSCRIPTION_CACHE_ONLY" /usr/bin/podkop 2>/dev/null
}

has_subscription_backend() {
	grep -q "get_subscription_items_cached" /usr/bin/podkop 2>/dev/null
}

has_actions_subscription_backend() {
	grep -q "subscription_speedtest" /usr/bin/podkop 2>/dev/null
}

has_batch_subscription_backend() {
	grep -q "set_subscription_links_enabled" /usr/bin/podkop 2>/dev/null
}

has_legacy_subscription_backend() {
	grep -q "set_subscription_link_enabled" /usr/bin/podkop 2>/dev/null
}

has_v0719_package_backend() {
	/usr/bin/podkop show_version 2>/dev/null | grep -q "^v0\\.7\\.19$"
}

tmp_dir="$(mktemp -d)"
backup_dir=""
trap 'rm -rf "$tmp_dir"' EXIT

[ -x /usr/bin/podkop ] || fail "Podkop is not installed at /usr/bin/podkop"
command -v base64 >/dev/null 2>&1 || fail "base64 utility is required"

download "$RAW_BASE/$LMO_FILE" "$tmp_dir/$LMO_FILE"
download "$RAW_BASE/$SUBSCRIPTIONS_FILE" "$tmp_dir/$SUBSCRIPTIONS_FILE"
download "$RAW_BASE/$MAIN_JS_FILE" "$tmp_dir/$MAIN_JS_FILE"

if has_latest_subscription_backend; then
	log "Subscription URLTest backend is already up to date; refreshing LuCI files."
	backup_runtime
elif has_subscription_backend; then
	log "Subscription URLTest backend is installed; applying maintenance upgrade."
	backup_runtime
elif has_actions_subscription_backend; then
	download "$RAW_BASE/$UI_FIX_BACKEND_FILE" "$tmp_dir/$UI_FIX_BACKEND_FILE"
	backup_runtime

	if ! sh "$tmp_dir/$UI_FIX_BACKEND_FILE"; then
		abort_with_restore "runtime UI fix backend upgrade failed"
	fi
elif has_batch_subscription_backend; then
	require_patch
	download "$RAW_BASE/$ACTIONS_UPGRADE_PATCH_FILE" "$tmp_dir/$ACTIONS_UPGRADE_PATCH_FILE"
	backup_runtime

	if ! patch -d / -p1 < "$tmp_dir/$ACTIONS_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime actions upgrade patch failed"
	fi
elif has_legacy_subscription_backend; then
	require_patch
	download "$RAW_BASE/$LEGACY_UPGRADE_PATCH_FILE" "$tmp_dir/$LEGACY_UPGRADE_PATCH_FILE"
	backup_runtime

	if ! patch -d / -p1 < "$tmp_dir/$LEGACY_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime legacy upgrade patch failed"
	fi
elif has_v0719_package_backend; then
	require_patch
	download "$RAW_BASE/$V0719_PATCH_FILE" "$tmp_dir/$V0719_PATCH_FILE"
	backup_runtime

	if ! patch -d / -p1 < "$tmp_dir/$V0719_PATCH_FILE"; then
		abort_with_restore "runtime v0.7.19 patch failed"
	fi
else
	require_patch
	download "$RAW_BASE/$PATCH_FILE" "$tmp_dir/$PATCH_FILE"
	backup_runtime

	if ! patch -d / -p1 < "$tmp_dir/$PATCH_FILE"; then
		abort_with_restore "runtime patch failed"
	fi
fi

if ! has_latest_subscription_backend; then
	require_patch
	download "$RAW_BASE/$CACHE_ONLY_UPGRADE_PATCH_FILE" "$tmp_dir/$CACHE_ONLY_UPGRADE_PATCH_FILE"

	if ! patch -d / -p1 < "$tmp_dir/$CACHE_ONLY_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime cache-only reload upgrade patch failed"
	fi
fi

mkdir -p /www/luci-static/resources/view/podkop
cp "$tmp_dir/$MAIN_JS_FILE" /www/luci-static/resources/view/podkop/main.js
cp "$tmp_dir/$SUBSCRIPTIONS_FILE" /www/luci-static/resources/view/podkop/subscriptions.js

mkdir -p /usr/lib/lua/luci/i18n
if ! base64 -d < "$tmp_dir/$LMO_FILE" > /usr/lib/lua/luci/i18n/podkop.ru.lmo; then
	abort_with_restore "failed to install LuCI translation"
fi

chmod 755 /usr/bin/podkop
[ -f /usr/lib/podkop/sing_box_config_facade.sh ] && chmod 644 /usr/lib/podkop/sing_box_config_facade.sh
[ -f /www/luci-static/resources/view/podkop/main.js ] && chmod 644 /www/luci-static/resources/view/podkop/main.js
[ -f /www/luci-static/resources/view/podkop/podkop.js ] && chmod 644 /www/luci-static/resources/view/podkop/podkop.js
[ -f /www/luci-static/resources/view/podkop/section.js ] && chmod 644 /www/luci-static/resources/view/podkop/section.js
[ -f /www/luci-static/resources/view/podkop/subscriptions.js ] && chmod 644 /www/luci-static/resources/view/podkop/subscriptions.js
chmod 644 /usr/lib/lua/luci/i18n/podkop.ru.lmo

if ! ash -n /usr/bin/podkop; then
	abort_with_restore "podkop syntax check failed"
fi

if [ -f /usr/lib/podkop/sing_box_config_facade.sh ] && ! ash -n /usr/lib/podkop/sing_box_config_facade.sh; then
	abort_with_restore "sing-box facade syntax check failed"
fi

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true

if [ -x /etc/init.d/podkop ]; then
	if ! /etc/init.d/podkop reload; then
		abort_with_restore "podkop reload failed"
	fi
fi

if command -v sing-box >/dev/null 2>&1 && [ -f /etc/sing-box/config.json ]; then
	if ! sing-box check -c /etc/sing-box/config.json; then
		abort_with_restore "sing-box config check failed"
	fi
fi

/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

log "Installed Subscription URLTest patch."
log "Backup saved at: $backup_dir"
cleanup_old_backups
