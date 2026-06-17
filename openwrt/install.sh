#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-v2026.06.18-subscriptions-patch-daemon-fix1}"
RAW_BASE="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PATCH_VERSION/openwrt}"
BACKUPS_KEEP="${PODKOP_PATCH_BACKUPS_KEEP:-2}"
PATCH_FILE="podkop-subscription-urltest-runtime.patch"
V0719_PATCH_FILE="podkop-subscription-v0719-runtime.patch"
CACHE_ONLY_UPGRADE_PATCH_FILE="podkop-subscription-cache-only-upgrade.patch"
SPEEDTEST_CACHE_UPGRADE_PATCH_FILE="podkop-subscription-speedtest-cache-upgrade.patch"
MAINTENANCE_UPGRADE_FILE="podkop-subscription-maintenance-upgrade.sh"
ACTIONS_UPGRADE_PATCH_FILE="podkop-subscription-actions-upgrade.patch"
LEGACY_UPGRADE_PATCH_FILE="podkop-subscription-legacy-upgrade.patch"
UI_FIX_BACKEND_FILE="podkop-actions-ui-fix.sh"
MAIN_JS_FILE="main.js"
LMO_FILE="podkop.ru.lmo.base64"
SUBSCRIPTIONS_FILE="subscriptions.js"

RUNTIME_FILES="
usr/bin/podkop
usr/lib/podkop/helpers.sh
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
	download_ok=0
	raw_host=""

	case "$url" in
		*raw.githubusercontent.com*)
			url="$url?podkop_patch=$(date +%s)"
			raw_host="raw.githubusercontent.com"
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		if curl -fsSL --connect-timeout 10 -m 30 "$url" -o "$out"; then
			download_ok=1
		elif [ "$raw_host" = "raw.githubusercontent.com" ]; then
			for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
				if curl -fsSL --connect-timeout 10 -m 30 \
					--resolve "raw.githubusercontent.com:443:$ip" \
					"$url" -o "$out"; then
					download_ok=1
					break
				fi
			done
		fi
	fi

	if [ "$download_ok" -ne 1 ] && command -v wget >/dev/null 2>&1; then
		if wget -T 30 -t 1 -q -O "$out" "$url"; then
			download_ok=1
		elif [ "$raw_host" = "raw.githubusercontent.com" ]; then
			clean_path="${url#https://raw.githubusercontent.com/}"
			clean_path="${clean_path%%\?*}"
			for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
				if wget -T 30 -t 1 --no-check-certificate --header="Host: raw.githubusercontent.com" \
					-q -O "$out" "https://$ip/$clean_path"; then
					download_ok=1
					break
				fi
			done
		fi
	fi

	[ "$download_ok" -eq 1 ] && [ -s "$out" ] || fail "failed to download $url"
}

require_patch() {
	if command -v patch >/dev/null 2>&1; then
		return 0
	fi

	if command -v apk >/dev/null 2>&1; then
		log "Installing patch utility with apk..."
		apk update >/dev/null 2>&1 || true
		apk add patch >/dev/null 2>&1 || true
	fi

	if command -v patch >/dev/null 2>&1; then
		return 0
	fi

	if command -v opkg >/dev/null 2>&1; then
		log "Installing patch utility with opkg..."
		opkg update >/dev/null 2>&1 || true
		opkg install patch >/dev/null 2>&1 || true
	fi

	command -v patch >/dev/null 2>&1 || fail "patch utility is required"
}

apply_runtime_patch() {
	patch_file="$1"

	patch -l -d / -p1 < "$patch_file"
}

stop_stale_list_update_downloads() {
	ps w 2>/dev/null | awk '
		/[p]odkop list_update/ { print $1 }
		/[w]get .*raw\.githubusercontent\.com\/itdoginfo\/allow-domains/ { print $1 }
		/[c]url .*raw\.githubusercontent\.com\/itdoginfo\/allow-domains/ { print $1 }
		/[w]get .*\/discord\.lst/ { print $1 }
		/[c]url .*\/discord\.lst/ { print $1 }
	' | while read -r pid; do
		case "$pid" in
			"" | *[!0-9]*)
				continue
				;;
		esac
		kill "$pid" 2>/dev/null || true
	done
}

run_podkop_reload() {
	reload_command="$1"
	reload_pid=""
	seconds=0
	timeout_seconds=90

	stop_stale_list_update_downloads
	sh -c "$reload_command" &
	reload_pid="$!"

	while kill -0 "$reload_pid" 2>/dev/null; do
		if [ "$seconds" -ge "$timeout_seconds" ]; then
			stop_stale_list_update_downloads
			kill "$reload_pid" 2>/dev/null || true
			sleep 2
			kill -9 "$reload_pid" 2>/dev/null || true
			wait "$reload_pid" 2>/dev/null || true
			return 1
		fi
		sleep 1
		seconds=$((seconds + 1))
	done

	wait "$reload_pid"
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
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

abort_with_restore() {
	restore_runtime
	fail "$1"
}

has_latest_subscription_backend() {
	count="$(grep -c "PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload" /usr/bin/podkop 2>/dev/null || true)"
	[ "${count:-0}" -ge 3 ] &&
		grep -q "benchmark_bytes" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_runtime_busy" /usr/bin/podkop 2>/dev/null &&
		grep -q "clash_api_wait_proxy_now" /usr/bin/podkop 2>/dev/null &&
		grep -q "stop_stale_list_update_downloads" /usr/bin/podkop 2>/dev/null &&
		grep -q "download_ok=0" /usr/bin/podkop 2>/dev/null &&
		grep -q "patch_update_download_v2" /usr/bin/podkop 2>/dev/null &&
		grep -q "patch_update_timeout_v1" /usr/bin/podkop 2>/dev/null &&
		grep -q "patch_update_start_stop_daemon_v1" /usr/bin/podkop 2>/dev/null &&
		grep -Fq 'wget -T 30 -t 1 -O "$filepath" "$url"' /usr/bin/podkop 2>/dev/null &&
		grep -Fq 'reduce .[] as $item' /usr/bin/podkop 2>/dev/null &&
		grep -Fq 'install.sh?t=$cache_buster' /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_action_lock_file" /usr/bin/podkop 2>/dev/null &&
		grep -q "raw.githubusercontent.com:443" /usr/lib/podkop/helpers.sh 2>/dev/null
}

has_cache_only_subscription_backend() {
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
	/usr/bin/podkop show_version 2>/dev/null | grep -Eq "^v?0\\.7\\.19$"
}

tmp_dir="$(mktemp -d)"
backup_dir=""
light_reload=0
trap 'rm -rf "$tmp_dir"' EXIT

[ -x /usr/bin/podkop ] || fail "Podkop is not installed at /usr/bin/podkop"
command -v base64 >/dev/null 2>&1 || fail "base64 utility is required"

download "$RAW_BASE/$LMO_FILE" "$tmp_dir/$LMO_FILE"
download "$RAW_BASE/$SUBSCRIPTIONS_FILE" "$tmp_dir/$SUBSCRIPTIONS_FILE"
download "$RAW_BASE/$MAIN_JS_FILE" "$tmp_dir/$MAIN_JS_FILE"

if has_latest_subscription_backend; then
	log "Subscription URLTest backend is already up to date; refreshing LuCI files."
	backup_runtime
	light_reload=1
elif has_cache_only_subscription_backend; then
	log "Subscription URLTest backend is installed; applying speedtest maintenance upgrade."
	backup_runtime
	light_reload=1
elif has_subscription_backend; then
	log "Subscription URLTest backend is installed; applying maintenance upgrade."
	backup_runtime
	light_reload=1
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

	if ! apply_runtime_patch "$tmp_dir/$ACTIONS_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime actions upgrade patch failed"
	fi
elif has_legacy_subscription_backend; then
	require_patch
	download "$RAW_BASE/$LEGACY_UPGRADE_PATCH_FILE" "$tmp_dir/$LEGACY_UPGRADE_PATCH_FILE"
	backup_runtime

	if ! apply_runtime_patch "$tmp_dir/$LEGACY_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime legacy upgrade patch failed"
	fi
elif has_v0719_package_backend; then
	require_patch
	download "$RAW_BASE/$V0719_PATCH_FILE" "$tmp_dir/$V0719_PATCH_FILE"
	backup_runtime

	if ! apply_runtime_patch "$tmp_dir/$V0719_PATCH_FILE"; then
		abort_with_restore "runtime v0.7.19 patch failed"
	fi
else
	require_patch
	download "$RAW_BASE/$PATCH_FILE" "$tmp_dir/$PATCH_FILE"
	backup_runtime

	if ! apply_runtime_patch "$tmp_dir/$PATCH_FILE"; then
		abort_with_restore "runtime patch failed"
	fi
fi

if ! has_latest_subscription_backend && has_subscription_backend; then
	download "$RAW_BASE/$MAINTENANCE_UPGRADE_FILE" "$tmp_dir/$MAINTENANCE_UPGRADE_FILE"

	if ! sh "$tmp_dir/$MAINTENANCE_UPGRADE_FILE"; then
		abort_with_restore "runtime maintenance upgrade failed"
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
	if [ "$light_reload" -eq 1 ]; then
		reload_command="PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload"
	else
		reload_command="PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload"
	fi

	if ! run_podkop_reload "$reload_command"; then
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
