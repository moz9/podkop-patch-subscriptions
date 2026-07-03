#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-main}"
RAW_BASE="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PATCH_VERSION/openwrt}"
PODKOP_OFFICIAL_INSTALL_URL="${PODKOP_OFFICIAL_INSTALL_URL:-https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh}"
PODKOP_PATCH_TARGET_PODKOP_VERSION="${PODKOP_PATCH_TARGET_PODKOP_VERSION:-0.7.20}"
PODKOP_PATCH_LATEST_RELEASE_URL="${PODKOP_PATCH_LATEST_RELEASE_URL:-https://api.github.com/repos/itdoginfo/podkop/releases/latest}"
PODKOP_PATCH_UPDATE_PODKOP="${PODKOP_PATCH_UPDATE_PODKOP:-1}"
BACKUPS_KEEP="${PODKOP_PATCH_BACKUPS_KEEP:-2}"
PATCH_FILE="podkop-subscription-urltest-runtime.patch"
V0719_PATCH_FILE="podkop-subscription-v0719-runtime.patch"
CACHE_ONLY_UPGRADE_PATCH_FILE="podkop-subscription-cache-only-upgrade.patch"
SPEEDTEST_CACHE_UPGRADE_PATCH_FILE="podkop-subscription-speedtest-cache-upgrade.patch"
MAINTENANCE_UPGRADE_FILE="podkop-subscription-maintenance-upgrade.sh"
INSTALL_MARKER="PODKOP_SUBSCRIPTIONS_PATCH_VERSION=20260627-mix-v1"
ACTIONS_UPGRADE_PATCH_FILE="podkop-subscription-actions-upgrade.patch"
LEGACY_UPGRADE_PATCH_FILE="podkop-subscription-legacy-upgrade.patch"
UI_FIX_BACKEND_FILE="podkop-actions-ui-fix.sh"
MAIN_JS_FILE="main.js"
SECTION_JS_FILE="section.js"
LMO_FILE="podkop.ru.lmo.base64"
SUBSCRIPTIONS_FILE="subscriptions.js"
LMO_DECODED_FILE="podkop.ru.lmo"

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

PERSISTENT_PATHS="
etc/config/podkop
etc/podkop
"

log() {
	printf '%s\n' "$*"
}

fail() {
	log "ERROR: $*"
	if command -v restore_if_needed >/dev/null 2>&1; then
		restore_if_needed
	fi
	exit 1
}

download() {
	url="$1"
	out="$2"
	download_ok=0
	raw_host=""
	download_log="${PODKOP_PATCH_DOWNLOAD_LOG:-/tmp/podkop-subscriptions-install-download.log}"

	case "$url" in
		file://*)
			src="${url#file://}"
			[ -s "$src" ] || fail "local source not found: $src"
			cp "$src" "$out" || fail "failed to copy $src"
			[ -s "$out" ] || fail "local source is empty: $src"
			return 0
			;;
		/*)
			[ -s "$url" ] || fail "local source not found: $url"
			cp "$url" "$out" || fail "failed to copy $url"
			[ -s "$out" ] || fail "local source is empty: $url"
			return 0
			;;
	esac

	case "$url" in
		*raw.githubusercontent.com*)
			url="$url?podkop_patch=$(date +%s)"
			raw_host="raw.githubusercontent.com"
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		if curl -fsSL --connect-timeout 10 -m 30 "$url" -o "$out" >> "$download_log" 2>&1; then
			download_ok=1
		elif [ "$raw_host" = "raw.githubusercontent.com" ]; then
			for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
				if curl -fsSL --connect-timeout 10 -m 30 \
					--resolve "raw.githubusercontent.com:443:$ip" \
					"$url" -o "$out" >> "$download_log" 2>&1; then
					download_ok=1
					break
				fi
			done
		fi
	fi

	if [ "$download_ok" -ne 1 ] && command -v wget >/dev/null 2>&1; then
		if wget -T 30 -q -O "$out" "$url" >> "$download_log" 2>&1; then
			download_ok=1
		elif [ "$raw_host" = "raw.githubusercontent.com" ]; then
			clean_path="${url#https://raw.githubusercontent.com/}"
			clean_path="${clean_path%%\?*}"
			for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
				if wget -T 30 --no-check-certificate --header="Host: raw.githubusercontent.com" \
					-q -O "$out" "https://$ip/$clean_path" >> "$download_log" 2>&1; then
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

	patch -l --batch -d / -p1 < "$patch_file"
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
	reload_log="${PODKOP_PATCH_RELOAD_LOG:-/tmp/podkop-subscriptions-install-reload.log}"
	seconds=0
	timeout_seconds=90

	: > "$reload_log"
	stop_stale_list_update_downloads
	sh -c "$reload_command" >> "$reload_log" 2>&1 &
	reload_pid="$!"

	while kill -0 "$reload_pid" 2>/dev/null; do
		if [ "$seconds" -ge "$timeout_seconds" ]; then
			stop_stale_list_update_downloads
			kill "$reload_pid" 2>/dev/null || true
			sleep 2
			kill -9 "$reload_pid" 2>/dev/null || true
			wait "$reload_pid" 2>/dev/null || true
			tail -n 20 "$reload_log" 2>/dev/null || true
			return 1
		fi
		sleep 1
		seconds=$((seconds + 1))
	done

	if ! wait "$reload_pid"; then
		tail -n 20 "$reload_log" 2>/dev/null || true
		return 1
	fi

	return 0
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
	restore_on_fail=1

	if [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ]; then
		log "Backup already exists: $backup_dir"
		return 0
	fi

	backup_dir="/root/podkop-patch-subscriptions-backup-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$backup_dir"

	for rel in $RUNTIME_FILES; do
		src="/$rel"
		if [ -e "$src" ]; then
			mkdir -p "$backup_dir/$(dirname "$rel")"
			cp -a "$src" "$backup_dir/$rel"
		fi
	done

	for rel in $PERSISTENT_PATHS; do
		src="/$rel"
		if [ -e "$src" ]; then
			mkdir -p "$backup_dir/$(dirname "$rel")"
			cp -a "$src" "$backup_dir/$rel"
		fi
	done

	log "Backup: $backup_dir"
	log "Backup size: $(get_path_size "$backup_dir")"
}

restore_persistent_paths() {
	for rel in $PERSISTENT_PATHS; do
		dst="/$rel"
		src="$backup_dir/$rel"
		if [ -e "$src" ]; then
			mkdir -p "$(dirname "$dst")"
			rm -rf "$dst"
			cp -a "$src" "$dst"
		fi
	done
}

restore_missing_persistent_paths() {
	for rel in $PERSISTENT_PATHS; do
		dst="/$rel"
		src="$backup_dir/$rel"
		if [ -e "$src" ] && [ ! -e "$dst" ]; then
			mkdir -p "$(dirname "$dst")"
			cp -a "$src" "$dst"
			log "Restored missing persistent path: /$rel"
		fi
	done
}

restore_runtime() {
	restore_done=1
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
	restore_persistent_paths
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

restore_if_needed() {
	if [ "${restore_on_fail:-0}" = "1" ] &&
		[ "${restore_done:-0}" != "1" ] &&
		[ -n "${backup_dir:-}" ] &&
		[ -d "$backup_dir" ]; then
		restore_runtime
	fi
}

abort_with_restore() {
	restore_on_fail=1
	restore_if_needed
	fail "$1"
}

has_latest_subscription_backend() {
	grep -Fq "$INSTALL_MARKER" /usr/bin/podkop 2>/dev/null && return 0

	count="$(grep -c "PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload" /usr/bin/podkop 2>/dev/null || true)"
	[ "${count:-0}" -ge 3 ] &&
		grep -q '^case "\$1" in' /usr/bin/podkop 2>/dev/null &&
		grep -q "get_subscription_items_cached" /usr/bin/podkop 2>/dev/null &&
		grep -q "set_subscription_links_enabled" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_update_json" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_speedtest" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_patch_update" /usr/bin/podkop 2>/dev/null &&
		grep -q "get_subscription_patch_update_status" /usr/bin/podkop 2>/dev/null &&
		grep -q "restore_community_subnet_cache_v2" /usr/bin/podkop 2>/dev/null &&
		grep -Fq 'reduce .[] as $item' /usr/bin/podkop 2>/dev/null &&
		grep -q "raw.githubusercontent.com:443" /usr/lib/podkop/helpers.sh 2>/dev/null &&
		grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608" /usr/bin/podkop 2>/dev/null &&
		grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS:-4" /usr/bin/podkop 2>/dev/null &&
		grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT:-15" /usr/bin/podkop 2>/dev/null &&
		grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0" /usr/bin/podkop 2>/dev/null &&
		grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3" /usr/bin/podkop 2>/dev/null &&
		grep -q -- "--connect-timeout 4" /usr/bin/podkop 2>/dev/null &&
		grep -q "time_starttransfer" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_speedtest_start" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_speedtest_stop" /usr/bin/podkop 2>/dev/null &&
		grep -q "get_subscription_speedtest_status" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_speedtest_restore_state_file" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_mix_manual_links_v1" /usr/bin/podkop 2>/dev/null &&
		grep -q "collect_urltest_proxy_links" /usr/bin/podkop 2>/dev/null &&
		grep -q "patch_update_podkop_update_v1" /usr/bin/podkop 2>/dev/null &&
		grep -q "Subscription download via service proxy failed; trying direct download" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription sources that could not be downloaded" /usr/bin/podkop 2>/dev/null &&
		grep -q "patch_update_noop_v1" /usr/bin/podkop 2>/dev/null &&
		grep -q "fakeip_route_check_v3" /usr/bin/podkop 2>/dev/null &&
		grep -q 'subscription_speedtest "$2" "$3"' /usr/bin/podkop 2>/dev/null &&
		grep -q -- '--arg state "running" --arg message "speedtest_running"' /usr/bin/podkop 2>/dev/null &&
		! grep -q "wget -T 30 -t" /usr/bin/podkop 2>/dev/null &&
		! grep -q "wget -T 30 -t" /usr/lib/podkop/helpers.sh 2>/dev/null
}

mark_latest_subscription_backend() {
	grep -Fq "$INSTALL_MARKER" /usr/bin/podkop 2>/dev/null && return 0
	printf '\n# %s\n' "$INSTALL_MARKER" >> /usr/bin/podkop
}

decode_lmo_asset() {
	if [ -s "$tmp_dir/$LMO_DECODED_FILE" ]; then
		return 0
	fi

	tr -d '\r\n\t ' < "$tmp_dir/$LMO_FILE" | base64 -d > "$tmp_dir/$LMO_DECODED_FILE"
}

luci_assets_current() {
	decode_lmo_asset || return 1

	[ -f /www/luci-static/resources/view/podkop/main.js ] &&
		cmp -s /www/luci-static/resources/view/podkop/main.js "$tmp_dir/$MAIN_JS_FILE" &&
		[ -f /www/luci-static/resources/view/podkop/section.js ] &&
		cmp -s /www/luci-static/resources/view/podkop/section.js "$tmp_dir/$SECTION_JS_FILE" &&
		[ -f /www/luci-static/resources/view/podkop/subscriptions.js ] &&
		cmp -s /www/luci-static/resources/view/podkop/subscriptions.js "$tmp_dir/$SUBSCRIPTIONS_FILE" &&
		[ -f /usr/lib/lua/luci/i18n/podkop.ru.lmo ] &&
		cmp -s /usr/lib/lua/luci/i18n/podkop.ru.lmo "$tmp_dir/$LMO_DECODED_FILE"
}

ensure_podkop_dispatcher() {
	target="$1"

	if grep -q '^case "\$1" in' "$target" 2>/dev/null; then
		return 0
	fi

	cat >> "$target" <<'DISPATCHER_EOF'

show_help() {
    cat <<'HELP_EOF'
Usage: podkop <command>

Available commands:
    start
    stop
    reload
    restart
    main
    list_update
    subscription_update
    subscription_update_json
    subscription_speedtest
    subscription_speedtest_start
    subscription_speedtest_stop
    get_subscription_speedtest_status
    subscription_patch_update
    get_subscription_patch_update_status
    check_proxy
    check_nft
    check_nft_rules
    check_sing_box
    check_logs
    check_sing_box_logs
    check_fakeip
    clash_api
    get_subscription_cached_links
    get_subscription_skipped_links
    get_subscription_items
    get_subscription_items_cached
    set_subscription_link_enabled
    set_subscription_links_enabled
    show_config
    show_version
    show_sing_box_config
    show_sing_box_version
    show_system_info
    get_status
    get_sing_box_status
    get_system_info
    check_dns_available
    global_check
HELP_EOF
}

case "$1" in
start)
    start
    ;;
stop)
    stop
    ;;
reload)
    reload
    ;;
restart)
    restart
    ;;
main)
    main
    ;;
list_update)
    list_update
    ;;
subscription_update)
    subscription_update "$2"
    ;;
subscription_update_json)
    subscription_update_json "$2"
    ;;
subscription_speedtest)
    subscription_speedtest "$2" "$3"
    ;;
subscription_speedtest_start)
    subscription_speedtest_start "$2" "$3"
    ;;
subscription_speedtest_stop)
    subscription_speedtest_stop
    ;;
get_subscription_speedtest_status)
    get_subscription_speedtest_status
    ;;
subscription_patch_update)
    subscription_patch_update
    ;;
get_subscription_patch_update_status)
    get_subscription_patch_update_status
    ;;
check_proxy)
    check_proxy
    ;;
check_nft)
    check_nft
    ;;
check_nft_rules)
    check_nft_rules
    ;;
check_sing_box)
    check_sing_box
    ;;
check_logs)
    check_logs
    ;;
check_sing_box_logs)
    check_sing_box_logs
    ;;
check_fakeip)
    check_fakeip
    ;;
clash_api)
    clash_api "$2" "$3" "$4"
    ;;
get_subscription_cached_links)
    get_subscription_cached_links "$2"
    ;;
get_subscription_skipped_links)
    get_subscription_skipped_links "$2"
    ;;
get_subscription_items)
    get_subscription_items "$2"
    ;;
get_subscription_items_cached)
    get_subscription_items_cached "$2"
    ;;
set_subscription_link_enabled)
    set_subscription_link_enabled "$2" "$3" "$4"
    ;;
set_subscription_links_enabled)
    shift
    set_subscription_links_enabled "$@"
    ;;
show_config)
    show_config
    ;;
show_version)
    show_version
    ;;
show_sing_box_config)
    show_sing_box_config
    ;;
show_sing_box_version)
    show_sing_box_version
    ;;
show_system_info)
    show_system_info
    ;;
get_status)
    get_status
    ;;
get_sing_box_status)
    get_sing_box_status
    ;;
get_system_info)
    get_system_info
    ;;
check_dns_available)
    check_dns_available
    ;;
global_check)
    global_check "${2:-}"
    ;;
*)
    show_help
    exit 1
    ;;
esac
DISPATCHER_EOF
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

normalize_version() {
	printf '%s\n' "$1" | sed 's/^v//' | awk -F. '{ printf "%d %d %d\n", $1, $2, $3 }'
}

version_ge() {
	current="$1"
	required="$2"
	[ -n "$current" ] && [ -n "$required" ] || return 1

	set -- $(normalize_version "$current") $(normalize_version "$required")
	cmaj="$1"; cmin="$2"; cpatch="$3"; rmaj="$4"; rmin="$5"; rpatch="$6"

	[ "$cmaj" -gt "$rmaj" ] && return 0
	[ "$cmaj" -lt "$rmaj" ] && return 1
	[ "$cmin" -gt "$rmin" ] && return 0
	[ "$cmin" -lt "$rmin" ] && return 1
	[ "$cpatch" -ge "$rpatch" ]
}

current_podkop_version() {
	/usr/bin/podkop show_version 2>/dev/null | sed 's/^v//' || true
}

download_optional() {
	url="$1"
	out="$2"

	if command -v curl >/dev/null 2>&1 &&
		curl -fsSL --connect-timeout 10 -m 30 "$url" -o "$out" >/dev/null 2>&1; then
		[ -s "$out" ] && return 0
	fi

	if command -v wget >/dev/null 2>&1 &&
		wget --no-check-certificate -T 30 -q -O "$out" "$url" >/dev/null 2>&1; then
		[ -s "$out" ] && return 0
	fi

	return 1
}

latest_official_podkop_version() {
	release_json="$tmp_dir/podkop-latest-release.json"
	version=""

	if ! download_optional "$PODKOP_PATCH_LATEST_RELEASE_URL" "$release_json"; then
		return 1
	fi

	version="$(
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' "$release_json" |
			head -n 1
	)"

	case "$version" in
	[0-9]*.[0-9]*.[0-9]*)
		printf '%s\n' "$version"
		return 0
		;;
	esac

	return 1
}

update_official_podkop_if_requested() {
	[ "${PODKOP_PATCH_UPDATE_PODKOP:-1}" = "1" ] || return 0

	current_version="$(current_podkop_version)"
	target_version="$PODKOP_PATCH_TARGET_PODKOP_VERSION"
	latest_version="$(latest_official_podkop_version || true)"

	if [ -n "$latest_version" ] && version_ge "$latest_version" "$target_version"; then
		target_version="$latest_version"
		log "Latest official Podkop version: $target_version"
	else
		log "Could not detect a newer official Podkop release; target is $target_version."
	fi

	if [ "${PODKOP_PATCH_FORCE_PODKOP_UPDATE:-0}" != "1" ] &&
		version_ge "$current_version" "$target_version"; then
		log "Official Podkop is already $current_version; target is $target_version. Skipping official update."
		return 0
	fi

	official_installer="$tmp_dir/podkop-official-install.sh"
	download "$PODKOP_OFFICIAL_INSTALL_URL" "$official_installer"

	if [ -x /usr/bin/podkop ] || [ -e /etc/config/podkop ] || [ -e /etc/podkop ]; then
		backup_runtime
	fi

	log "Updating official Podkop before applying Subscription URLTest patch."
	if ! sh "$official_installer"; then
		if [ -n "${backup_dir:-}" ]; then
			restore_runtime
		fi

		current_version="$(current_podkop_version)"
		if version_ge "$current_version" "$target_version"; then
			log "Official Podkop update failed, but installed version $current_version already meets target $target_version. Continuing with Subscription URLTest patch."
			return 0
		fi

		fail "official Podkop update failed"
	fi

	[ -x /usr/bin/podkop ] || fail "Official Podkop installer finished, but /usr/bin/podkop is missing"
	if [ -n "${backup_dir:-}" ]; then
		restore_missing_persistent_paths
	fi
}

tmp_dir="$(mktemp -d)"
backup_dir=""
restore_on_fail=0
restore_done=0
light_reload=0
trap 'rm -rf "$tmp_dir"' EXIT

command -v base64 >/dev/null 2>&1 || fail "base64 utility is required"

update_official_podkop_if_requested

[ -x /usr/bin/podkop ] || fail "Podkop is not installed at /usr/bin/podkop"

download "$RAW_BASE/$LMO_FILE" "$tmp_dir/$LMO_FILE"
download "$RAW_BASE/$SUBSCRIPTIONS_FILE" "$tmp_dir/$SUBSCRIPTIONS_FILE"
download "$RAW_BASE/$MAIN_JS_FILE" "$tmp_dir/$MAIN_JS_FILE"
download "$RAW_BASE/$SECTION_JS_FILE" "$tmp_dir/$SECTION_JS_FILE"

if [ "${PODKOP_PATCH_FORCE:-0}" != "1" ] && has_latest_subscription_backend && luci_assets_current; then
	log "Subscription URLTest patch is already up to date; nothing to do."
	log "PODKOP_PATCH_NOOP=1"
	exit 0
fi

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
	rm -f /www/luci-static/resources/view/podkop/subscriptions.js

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

for runtime_file in /usr/bin/podkop /usr/lib/podkop/helpers.sh; do
	if [ -f "$runtime_file" ]; then
		sed -i 's/wget -T 30 -t 1 /wget -T 30 /g' "$runtime_file"
	fi
done

if [ -f /usr/bin/podkop ]; then
	sed -i 's#CLASH_URL="$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT"#CLASH_URL="http://$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT"#g' /usr/bin/podkop
	ensure_podkop_dispatcher /usr/bin/podkop
	mark_latest_subscription_backend
fi

if grep -q "get_subscription_benchmark_bytes" /usr/bin/podkop 2>/dev/null &&
	{ ! grep -q "^get_subscription_benchmark_bytes()" /usr/bin/podkop 2>/dev/null ||
		! grep -q "^get_subscription_benchmark_streams()" /usr/bin/podkop 2>/dev/null ||
		! grep -q "^get_subscription_benchmark_timeout()" /usr/bin/podkop 2>/dev/null ||
		! grep -q "^get_subscription_benchmark_warmup_bytes()" /usr/bin/podkop 2>/dev/null ||
		! grep -q "^get_subscription_benchmark_attempts()" /usr/bin/podkop 2>/dev/null ||
		! grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3" /usr/bin/podkop 2>/dev/null; }; then
	benchmark_helpers="$tmp_dir/subscription-benchmark-helpers.sh"
	cat > "$benchmark_helpers" <<'BENCHMARK_HELPERS_EOF'
get_subscription_benchmark_port() {
    echo "42080"
}

get_subscription_benchmark_bytes() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608}"
}

get_subscription_benchmark_streams() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS:-4}"
}

get_subscription_benchmark_timeout() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT:-15}"
}

get_subscription_benchmark_warmup_bytes() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0}"
}

get_subscription_benchmark_attempts() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3}"
}
BENCHMARK_HELPERS_EOF

	awk -v helpers="$benchmark_helpers" '
	BEGIN {
		inserted = 0
		skip = 0
	}

	$0 ~ /^get_subscription_benchmark_(port|bytes|streams|timeout|warmup_bytes|attempts)\(\) \{$/ {
		skip = 1
		next
	}

	skip && $0 == "}" {
		skip = 0
		next
	}

	skip {
		next
	}

	!inserted && $0 == "subscription_speedtest() {" {
		while ((getline line < helpers) > 0) {
			print line
		}
		print ""
		inserted = 1
	}

	{ print }
	' /usr/bin/podkop > "$tmp_dir/podkop.benchmark" || abort_with_restore "failed to restore subscription benchmark helpers"
	cat "$tmp_dir/podkop.benchmark" > /usr/bin/podkop
fi

mkdir -p /www/luci-static/resources/view/podkop
cp "$tmp_dir/$MAIN_JS_FILE" /www/luci-static/resources/view/podkop/main.js
cp "$tmp_dir/$SECTION_JS_FILE" /www/luci-static/resources/view/podkop/section.js
cp "$tmp_dir/$SUBSCRIPTIONS_FILE" /www/luci-static/resources/view/podkop/subscriptions.js

mkdir -p /usr/lib/lua/luci/i18n
if ! decode_lmo_asset; then
	abort_with_restore "failed to install LuCI translation"
fi
cp "$tmp_dir/$LMO_DECODED_FILE" /usr/lib/lua/luci/i18n/podkop.ru.lmo || abort_with_restore "failed to install LuCI translation"

chmod 755 /usr/bin/podkop
[ -f /usr/lib/podkop/sing_box_config_facade.sh ] && chmod 644 /usr/lib/podkop/sing_box_config_facade.sh
[ -f /www/luci-static/resources/view/podkop/main.js ] && chmod 644 /www/luci-static/resources/view/podkop/main.js
[ -f /www/luci-static/resources/view/podkop/podkop.js ] && chmod 644 /www/luci-static/resources/view/podkop/podkop.js
[ -f /www/luci-static/resources/view/podkop/section.js ] && chmod 644 /www/luci-static/resources/view/podkop/section.js
[ -f /www/luci-static/resources/view/podkop/subscriptions.js ] && chmod 644 /www/luci-static/resources/view/podkop/subscriptions.js
chmod 644 /usr/lib/lua/luci/i18n/podkop.ru.lmo

ensure_podkop_dispatcher /usr/bin/podkop

if ! ash -n /usr/bin/podkop; then
	abort_with_restore "podkop syntax check failed"
fi

if [ -z "$(/usr/bin/podkop show_version 2>/dev/null)" ]; then
	abort_with_restore "podkop command dispatcher check failed"
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
