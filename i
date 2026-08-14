#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-main}"
RAW_BASE="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PATCH_VERSION/openwrt}"
PODKOP_OFFICIAL_INSTALL_URL="${PODKOP_OFFICIAL_INSTALL_URL:-https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh}"
PODKOP_PATCH_TARGET_PODKOP_VERSION="${PODKOP_PATCH_TARGET_PODKOP_VERSION:-0.7.21}"
PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS="${PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS:-0.7.19 0.7.20 0.7.21}"
PODKOP_PATCH_LATEST_RELEASE_URL="${PODKOP_PATCH_LATEST_RELEASE_URL:-https://api.github.com/repos/itdoginfo/podkop/releases/latest}"
PODKOP_PATCH_UPDATE_PODKOP_WAS_SET=0
[ "${PODKOP_PATCH_UPDATE_PODKOP+x}" = x ] && PODKOP_PATCH_UPDATE_PODKOP_WAS_SET=1
PODKOP_PATCH_FORCE_PODKOP_UPDATE_WAS_SET=0
[ "${PODKOP_PATCH_FORCE_PODKOP_UPDATE+x}" = x ] && PODKOP_PATCH_FORCE_PODKOP_UPDATE_WAS_SET=1
PODKOP_PATCH_UPDATE_PODKOP="${PODKOP_PATCH_UPDATE_PODKOP:-1}"
BACKUPS_KEEP="${PODKOP_PATCH_BACKUPS_KEEP:-2}"
PATCH_FILE="podkop-subscription-urltest-runtime.patch"
V0719_PATCH_FILE="podkop-subscription-v0719-runtime.patch"
CACHE_ONLY_UPGRADE_PATCH_FILE="podkop-subscription-cache-only-upgrade.patch"
SPEEDTEST_CACHE_UPGRADE_PATCH_FILE="podkop-subscription-speedtest-cache-upgrade.patch"
MAINTENANCE_UPGRADE_FILE="podkop-subscription-maintenance-upgrade.sh"
APPLY_V2_UPGRADE_FILE="podkop-subscription-apply-v2-upgrade.sh"
INSTALL_MARKER="PODKOP_SUBSCRIPTIONS_PATCH_VERSION=20260814-google-play-guard-v1"
ACTIONS_UPGRADE_PATCH_FILE="podkop-subscription-actions-upgrade.patch"
LEGACY_UPGRADE_PATCH_FILE="podkop-subscription-legacy-upgrade.patch"
UI_FIX_BACKEND_FILE="podkop-actions-ui-fix.sh"
MAIN_JS_FILE="main.js"
SECTION_JS_FILE="section.js"
LMO_FILE="podkop.ru.lmo.base64"
SUBSCRIPTIONS_FILE="subscriptions.js"
SETTINGS_JS_FILE="settings.js"
DASHBOARD_JS_FILE="dashboard.js"
DIAGNOSTIC_JS_FILE="diagnostic.js"
PODKOP_JS_FILE="podkop.js"
DNS_OPTIMIZER_FILE="podkop-dns-optimizer"
DNS_OPTIMIZER_VERSION="20260814-dns-optimizer-v16"
DNS_OPTIMIZER_GOOGLE_PLAY_GUARD_CAPABILITY="google_play_dns_transport_guard_v1"
DNS_OPTIMIZER_CHATGPT_GUARD_CAPABILITY="chatgpt_dns_transport_guard_v1"
DNS_FAILOVER_FILE="podkop-dns-failover"
DNS_FAILOVER_INIT_FILE="podkop-dns-failover.init"
DNS_FAILOVER_VERSION="20260813-dns-failover-v3"
DNS_FAILOVER_UPGRADE_FILE="podkop-dns-failover-upgrade.sh"
UPDATE_MANAGER_FILE="podkop-update-manager"
UPDATE_MANAGER_VERSION="20260813-update-manager-v3"
UPDATE_CENTER_UPGRADE_FILE="podkop-update-center-upgrade.sh"
LMO_DECODED_FILE="podkop.ru.lmo"
RUNTIME_0720_PODKOP_FILE="runtime-0.7.20/usr/bin/podkop"
RUNTIME_0720_PODKOP_JS_FILE="runtime-0.7.20/www/luci-static/resources/view/podkop/podkop.js"
LUCI_MODULE_NAMESPACE="podkop_patch_20260814_google_play_guard_v1"
LUCI_MODULE_ENTRY="$LUCI_MODULE_NAMESPACE/podkop"
LUCI_VIEW_ROOT="${PODKOP_PATCH_LUCI_VIEW_ROOT:-/www/luci-static/resources/view}"
LUCI_MENU_FILE="${PODKOP_PATCH_LUCI_MENU_FILE:-/usr/share/luci/menu.d/luci-app-podkop.json}"
INSTALLER_ACTION_LOCK_FILE="${PODKOP_PATCH_ACTION_LOCK_FILE:-/tmp/podkop-subscription-action.lock}"
INSTALLER_ACTION_LOCK_DIR="${PODKOP_PATCH_ACTION_LOCK_DIR:-/tmp/podkop-subscription-action.lock.d}"
BACKUP_ROOT="${PODKOP_PATCH_BACKUP_ROOT:-/root}"
PODKOP_INIT_SCRIPT="${PODKOP_PATCH_PODKOP_INIT_SCRIPT:-/etc/init.d/podkop}"
PODKOP_RUNTIME_BIN="${PODKOP_PATCH_PODKOP_RUNTIME_BIN:-/usr/bin/podkop}"
DNS_FAILOVER_INIT_SCRIPT="${PODKOP_PATCH_DNS_FAILOVER_INIT_SCRIPT:-/etc/init.d/podkop-dns-failover}"

RUNTIME_FILES="
usr/bin/podkop
usr/bin/podkop-dns-optimizer
usr/bin/podkop-dns-failover
usr/bin/podkop-update-manager
etc/init.d/podkop-dns-failover
etc/rc.d/K10podkop-dns-failover
etc/rc.d/S100podkop-dns-failover
usr/lib/podkop/helpers.sh
usr/lib/podkop/sing_box_config_facade.sh
usr/share/rpcd/acl.d/luci-app-podkop.json
usr/share/luci/menu.d/luci-app-podkop.json
www/luci-static/resources/view/podkop/main.js
www/luci-static/resources/view/podkop/podkop.js
www/luci-static/resources/view/podkop/section.js
www/luci-static/resources/view/podkop/subscriptions.js
www/luci-static/resources/view/podkop/settings.js
www/luci-static/resources/view/podkop/dashboard.js
www/luci-static/resources/view/podkop/diagnostic.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/main.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/podkop.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/section.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/subscriptions.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/settings.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/dashboard.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/diagnostic.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/main.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/podkop.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/section.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/subscriptions.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/settings.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/dashboard.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v2/diagnostic.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/main.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/podkop.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/section.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/subscriptions.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/settings.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/dashboard.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v3/diagnostic.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/main.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/podkop.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/section.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/subscriptions.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/settings.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/dashboard.js
www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v4/diagnostic.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/main.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/podkop.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/section.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/subscriptions.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/settings.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/dashboard.js
www/luci-static/resources/view/podkop_patch_20260814_google_play_guard_v1/diagnostic.js
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

install_prebuilt_0720_runtime() {
	mkdir -p /usr/bin "$LUCI_VIEW_ROOT/podkop"
	cp "$tmp_dir/podkop.runtime-0.7.20" /usr/bin/podkop
	cp "$tmp_dir/podkop.js.runtime-0.7.20" "$LUCI_VIEW_ROOT/podkop/podkop.js"
}

prefetch_patch_assets() {
	download "$RAW_BASE/$LMO_FILE" "$tmp_dir/$LMO_FILE"
	download "$RAW_BASE/$SUBSCRIPTIONS_FILE" "$tmp_dir/$SUBSCRIPTIONS_FILE"
	download "$RAW_BASE/$MAIN_JS_FILE" "$tmp_dir/$MAIN_JS_FILE"
	download "$RAW_BASE/$SECTION_JS_FILE" "$tmp_dir/$SECTION_JS_FILE"
	download "$RAW_BASE/$SETTINGS_JS_FILE" "$tmp_dir/$SETTINGS_JS_FILE"
	download "$RAW_BASE/$DASHBOARD_JS_FILE" "$tmp_dir/$DASHBOARD_JS_FILE"
	download "$RAW_BASE/$DIAGNOSTIC_JS_FILE" "$tmp_dir/$DIAGNOSTIC_JS_FILE"
	download "$RAW_BASE/$PODKOP_JS_FILE" "$tmp_dir/$PODKOP_JS_FILE"
	download "$RAW_BASE/$DNS_OPTIMIZER_FILE" "$tmp_dir/$DNS_OPTIMIZER_FILE"
	download "$RAW_BASE/$DNS_FAILOVER_FILE" "$tmp_dir/$DNS_FAILOVER_FILE"
	download "$RAW_BASE/$DNS_FAILOVER_INIT_FILE" "$tmp_dir/$DNS_FAILOVER_INIT_FILE"
	download "$RAW_BASE/$DNS_FAILOVER_UPGRADE_FILE" "$tmp_dir/$DNS_FAILOVER_UPGRADE_FILE"
	download "$RAW_BASE/$APPLY_V2_UPGRADE_FILE" "$tmp_dir/$APPLY_V2_UPGRADE_FILE"
	download "$RAW_BASE/$UPDATE_MANAGER_FILE" "$tmp_dir/$UPDATE_MANAGER_FILE"
	download "$RAW_BASE/$UI_FIX_BACKEND_FILE" "$tmp_dir/$UI_FIX_BACKEND_FILE"
	download "$RAW_BASE/$ACTIONS_UPGRADE_PATCH_FILE" "$tmp_dir/$ACTIONS_UPGRADE_PATCH_FILE"
	download "$RAW_BASE/$LEGACY_UPGRADE_PATCH_FILE" "$tmp_dir/$LEGACY_UPGRADE_PATCH_FILE"
	download "$RAW_BASE/$V0719_PATCH_FILE" "$tmp_dir/$V0719_PATCH_FILE"
	download "$RAW_BASE/$MAINTENANCE_UPGRADE_FILE" "$tmp_dir/$MAINTENANCE_UPGRADE_FILE"
	download "$RAW_BASE/$UPDATE_CENTER_UPGRADE_FILE" "$tmp_dir/$UPDATE_CENTER_UPGRADE_FILE"
	download "$RAW_BASE/$RUNTIME_0720_PODKOP_FILE" "$tmp_dir/podkop.runtime-0.7.20"
	download "$RAW_BASE/$RUNTIME_0720_PODKOP_JS_FILE" "$tmp_dir/podkop.js.runtime-0.7.20"
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

podkop_dnsmasq_configured() {
	uci get dhcp.@dnsmasq[0].server 2>/dev/null | grep -Fxq "127.0.0.42" &&
		[ "$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ] &&
		[ "$(uci get dhcp.@dnsmasq[0].cachesize 2>/dev/null)" = "0" ]
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

	for dir in $(ls -1dt "$BACKUP_ROOT"/podkop-patch-subscriptions-backup-* 2>/dev/null); do
		[ -d "$dir" ] || continue
		count=$((count + 1))
		if [ "$count" -gt "$keep" ]; then
			if rm -rf "$dir"; then
				log "Removed old backup: $dir"
			else
				log "WARNING: failed to remove old backup: $dir"
			fi
		fi
	done

	log "Keeping last $keep backup(s)."
	return 0
}

dns_optimizer_candidate_set_matches() {
	local actual="$1"
	local expected="$2"
	local actual_sorted expected_sorted

	actual_sorted="$(printf '%s\n' "$actual" | awk '{ for (i = 1; i <= NF; i++) print $i }' | LC_ALL=C sort)"
	expected_sorted="$(printf '%s\n' "$expected" | awk '{ for (i = 1; i <= NF; i++) print $i }' | LC_ALL=C sort)"

	[ -n "$actual_sorted" ] && [ "$actual_sorted" = "$expected_sorted" ]
}

migrate_dns_optimizer_candidate_defaults() {
	local old_v1_normal="cloudflare google yandex adguard_unfiltered controld_unfiltered mullvad"
	local old_v2_normal="cloudflare google adguard_unfiltered controld_unfiltered mullvad"
	local old_bootstrap="cloudflare_1 cloudflare_2 google_1 google_2 yandex_1 yandex_2 adguard_unfiltered controld_unfiltered"
	local new_normal="cloudflare google controld_unfiltered"
	local new_bootstrap="cloudflare_1 cloudflare_2 google_1 google_2 yandex_1 yandex_2 controld_unfiltered"
	local current_normal current_bootstrap changed pending_changes

	pending_changes="$(uci changes podkop 2>/dev/null || true)"
	if [ -n "$pending_changes" ]; then
		log "ERROR: Podkop has pending UCI changes; refusing DNS default migration without committing or discarding them."
		return 2
	fi

	current_normal="$(uci -q get podkop.settings.dns_optimizer_candidates 2>/dev/null || true)"
	current_bootstrap="$(uci -q get podkop.settings.dns_optimizer_bootstrap_candidates 2>/dev/null || true)"
	changed=0

	if dns_optimizer_candidate_set_matches "$current_normal" "$old_v1_normal" ||
		dns_optimizer_candidate_set_matches "$current_normal" "$old_v2_normal"; then
		if ! uci set "podkop.settings.dns_optimizer_candidates=$new_normal"; then
			uci revert podkop >/dev/null 2>&1 || true
			return 1
		fi
		changed=1
	fi

	if dns_optimizer_candidate_set_matches "$current_bootstrap" "$old_bootstrap"; then
		if ! uci set "podkop.settings.dns_optimizer_bootstrap_candidates=$new_bootstrap"; then
			uci revert podkop >/dev/null 2>&1 || true
			return 1
		fi
		changed=1
	fi

	[ "$changed" -eq 1 ] || return 0
	if ! uci commit podkop; then
		uci revert podkop >/dev/null 2>&1 || true
		return 1
	fi
	log "Migrated stock DNS optimizer selections to the v3 defaults."
}

ensure_backup_dir() {
	[ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ] && return 0

	backup_dir="$(mktemp -d "$BACKUP_ROOT/podkop-patch-subscriptions-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || {
		backup_dir=""
		fail "failed to create a unique backup directory"
	}
}

backup_persistent_paths() {
	ensure_backup_dir
	persistent_backup_dir="$backup_dir/pre-official-persistent"
	[ ! -e "$persistent_backup_dir" ] || fail "pre-official persistent backup already exists"
	mkdir "$persistent_backup_dir" || fail "failed to create pre-official persistent backup"

	for rel in $PERSISTENT_PATHS; do
		src="/$rel"
		if [ -e "$src" ]; then
			mkdir -p "$persistent_backup_dir/$(dirname "$rel")" &&
				cp -a "$src" "$persistent_backup_dir/$rel" ||
				fail "failed to back up persistent path before official Podkop update: /$rel"
		fi
	done
	log "Persistent pre-update backup: $backup_dir"
}

backup_runtime() {
	[ "${transaction_phase:-}" = "prepatch" ] || fail "runtime backup is only allowed immediately before patch mutations"
	[ "${backup_complete:-0}" != "1" ] || fail "patch rollback backup is already complete"

	restore_on_fail=0
	backup_complete=0
	rollback_generation="$(podkop_package_generation)" || fail "could not read Podkop package generation before patching"
	ensure_backup_dir
	rollback_dir="$backup_dir/patch-rollback"
	rollback_tmp="$backup_dir/.patch-rollback.$$"
	[ ! -e "$rollback_dir" ] && [ ! -e "$rollback_tmp" ] || fail "patch rollback backup already exists"
	mkdir "$rollback_tmp" || fail "failed to create patch rollback backup"

	for rel in $RUNTIME_FILES; do
		src="/$rel"
		if [ -e "$src" ]; then
			if ! mkdir -p "$rollback_tmp/$(dirname "$rel")" ||
				! cp -a "$src" "$rollback_tmp/$rel"; then
				rm -rf "$rollback_tmp"
				fail "failed to back up runtime path: /$rel"
			fi
		fi
	done

	for rel in $PERSISTENT_PATHS; do
		src="/$rel"
		if [ -e "$src" ]; then
			if ! mkdir -p "$rollback_tmp/$(dirname "$rel")" ||
				! cp -a "$src" "$rollback_tmp/$rel"; then
				rm -rf "$rollback_tmp"
				fail "failed to back up persistent path: /$rel"
			fi
		fi
	done

	current_generation="$(podkop_package_generation)" || {
		rm -rf "$rollback_tmp"
		fail "could not verify Podkop package generation after backup"
	}
	[ "$current_generation" = "$rollback_generation" ] || {
		rm -rf "$rollback_tmp"
		fail "Podkop package generation changed while the patch backup was being created"
	}
	capture_patch_service_state
	mv "$rollback_tmp" "$rollback_dir" || {
		rm -rf "$rollback_tmp"
		fail "failed to finalize patch rollback backup"
	}

	backup_complete=1
	restore_done=0
	restore_on_fail=1
	transaction_phase="patching"
	log "Backup: $backup_dir"
	log "Backup size: $(get_path_size "$backup_dir")"
}

restore_persistent_paths() {
	source_root="${1:-$rollback_dir}"
	persistent_restore_ok=1
	for rel in $PERSISTENT_PATHS; do
		dst="/$rel"
		src="$source_root/$rel"
		if [ -e "$src" ]; then
			if ! mkdir -p "$(dirname "$dst")" ||
				! rm -rf "$dst" ||
				! cp -a "$src" "$dst"; then
				persistent_restore_ok=0
			fi
		elif ! rm -rf "$dst"; then
			persistent_restore_ok=0
		fi
	done

	[ "$persistent_restore_ok" -eq 1 ]
}

restore_missing_persistent_paths() {
	source_root="${1:-$persistent_backup_dir}"
	[ -n "$source_root" ] && [ -d "$source_root" ] || return 0
	persistent_restore_ok=1
	for rel in $PERSISTENT_PATHS; do
		dst="/$rel"
		src="$source_root/$rel"
		if [ -e "$src" ] && [ ! -e "$dst" ]; then
			if mkdir -p "$(dirname "$dst")" && cp -a "$src" "$dst"; then
				log "Restored missing persistent path: /$rel"
			else
				persistent_restore_ok=0
			fi
		fi
	done

	[ "$persistent_restore_ok" -eq 1 ]
}

reject_official_podkop_result() {
	rejection_message="$1"
	if ! restore_missing_persistent_paths "$persistent_backup_dir"; then
		fail "$rejection_message; restoring missing persistent Podkop state also failed${backup_dir:+; persistent backup: $backup_dir}"
	fi
	fail "$rejection_message${backup_dir:+; persistent backup: $backup_dir}"
}

query_service_running_state() {
	service_name="$1"
	command -v ubus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
		printf '%s\n' unknown
		return 0
	}
	service_json="$(ubus call service list "{\"name\":\"$service_name\"}" 2>/dev/null)" || {
		printf '%s\n' unknown
		return 0
	}
	printf '%s\n' "$service_json" | jq -e --arg service "$service_name" \
		'has($service) and (.[$service] | type == "object") and (
			((.[$service].instances?) | type) == "null" or
			(((.[$service].instances?) | type) == "object" and
			 ((.[$service].instances | to_entries) | all(.[]; (.value | type) == "object" and (.value.running | type) == "boolean")))
		)' >/dev/null 2>&1 || {
		printf '%s\n' unknown
		return 0
	}
	if printf '%s\n' "$service_json" | jq -e --arg service "$service_name" \
		'([((.[$service].instances? // {}) | to_entries[]?) | .value.running == true] | any)' >/dev/null 2>&1; then
		printf '%s\n' running
	else
		printf '%s\n' stopped
	fi
}

capture_patch_service_state() {
	if [ ! -x "$DNS_FAILOVER_INIT_SCRIPT" ]; then
		dns_failover_service_state="absent"
	else
		dns_failover_service_state="$(query_service_running_state podkop-dns-failover)"
	fi
	case "$dns_failover_service_state" in
		running | stopped | unknown | absent) ;;
		*) dns_failover_service_state="unknown" ;;
	esac
}

restart_podkop_after_restore() {
	[ -x "$PODKOP_INIT_SCRIPT" ] || return 1
	[ -x "$PODKOP_RUNTIME_BIN" ] || return 1
	run_podkop_reload "PODKOP_SKIP_LIST_UPDATE=1 $PODKOP_RUNTIME_BIN restart"
}

restore_patch_service_state() {
	service_restore_ok=1
	restart_podkop_after_restore || service_restore_ok=0

	case "${dns_failover_service_state:-unknown}" in
	stopped)
		[ ! -x "$DNS_FAILOVER_INIT_SCRIPT" ] || "$DNS_FAILOVER_INIT_SCRIPT" stop >/dev/null 2>&1 || service_restore_ok=0
		;;
	absent)
		[ ! -e "$DNS_FAILOVER_INIT_SCRIPT" ] || service_restore_ok=0
		;;
	*)
		if [ -x "$DNS_FAILOVER_INIT_SCRIPT" ]; then
			"$DNS_FAILOVER_INIT_SCRIPT" restart >/dev/null 2>&1 || service_restore_ok=0
		else
			service_restore_ok=0
		fi
		;;
	esac

	[ "$service_restore_ok" -eq 1 ]
}

restore_runtime() {
	[ "${transaction_phase:-}" = "patching" ] || {
		log "ERROR: refusing runtime rollback outside the patching phase"
		return 1
	}
	[ "${backup_complete:-0}" = "1" ] && [ -n "${rollback_dir:-}" ] && [ -d "$rollback_dir" ] || {
		log "ERROR: refusing runtime rollback without a complete patch snapshot"
		return 1
	}
	current_generation="$(podkop_package_generation)" || {
		log "ERROR: refusing runtime rollback because Podkop package generation is unavailable"
		return 1
	}
	[ "$current_generation" = "${rollback_generation:-}" ] || {
		log "ERROR: refusing runtime rollback across Podkop package generations"
		return 1
	}

	runtime_restore_ok=1
	log "Restoring backup..."
	[ ! -x "$DNS_FAILOVER_INIT_SCRIPT" ] || "$DNS_FAILOVER_INIT_SCRIPT" stop >/dev/null 2>&1 || true
	for rel in $RUNTIME_FILES; do
		dst="/$rel"
		src="$rollback_dir/$rel"
		if [ -e "$src" ]; then
			if ! mkdir -p "$(dirname "$dst")" ||
				! rm -rf "$dst" ||
				! cp -a "$src" "$dst"; then
				runtime_restore_ok=0
			fi
		elif ! rm -rf "$dst"; then
			runtime_restore_ok=0
		fi
	done
	restore_persistent_paths "$rollback_dir" || runtime_restore_ok=0
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
	if [ "$runtime_restore_ok" -eq 1 ]; then
		restore_patch_service_state || runtime_restore_ok=0
	fi

	if [ "$runtime_restore_ok" -eq 1 ]; then
		restore_done=1
		return 0
	fi

	log "ERROR: backup restoration was incomplete; retrying on installer exit"
	return 1
}

restore_if_needed() {
	if [ "${restore_on_fail:-0}" = "1" ] &&
		[ "${transaction_phase:-}" = "patching" ] &&
		[ "${backup_complete:-0}" = "1" ] &&
		[ "${restore_done:-0}" != "1" ] &&
		[ -n "${rollback_dir:-}" ] &&
		[ -d "$rollback_dir" ]; then
		restore_runtime
	fi
}

installer_lock_pid_alive() {
	pid="$1"

	[ -n "$pid" ] || return 1
	case "$pid" in
	*[!0-9]*)
		return 1
		;;
	esac

	[ -d "/proc/$pid" ]
}

installer_legacy_lock_busy() {
	[ -e "$INSTALLER_ACTION_LOCK_FILE" ] || return 1

	pid="$(awk 'NR == 1 {print $1}' "$INSTALLER_ACTION_LOCK_FILE" 2>/dev/null)"
	[ -n "$pid" ] || return 0
	if installer_lock_pid_alive "$pid"; then
		return 0
	fi

	rm -f "$INSTALLER_ACTION_LOCK_FILE" 2>/dev/null || return 0
	return 1
}

installer_mutation_lock_busy() {
	if [ -d "$INSTALLER_ACTION_LOCK_DIR" ]; then
		pid="$(awk 'NR == 1 {print $1}' "$INSTALLER_ACTION_LOCK_DIR/owner" 2>/dev/null)"
		[ -n "$pid" ] || return 0
		if installer_lock_pid_alive "$pid"; then
			return 0
		fi

		rm -f "$INSTALLER_ACTION_LOCK_DIR/owner"
		rmdir "$INSTALLER_ACTION_LOCK_DIR" 2>/dev/null || return 0
	fi

	installer_legacy_lock_busy
}

installer_mutation_lock_acquire() {
	if installer_mutation_lock_busy; then
		return 1
	fi

	mkdir "$INSTALLER_ACTION_LOCK_DIR" 2>/dev/null || return 1
	if ! printf '%s %s %s\n' "$$" installer "$(date +%s 2>/dev/null || date)" > "$INSTALLER_ACTION_LOCK_DIR/owner"; then
		rmdir "$INSTALLER_ACTION_LOCK_DIR" 2>/dev/null || true
		return 1
	fi

	if installer_legacy_lock_busy; then
		installer_mutation_lock_release
		return 1
	fi
	if ! (set -C; printf '%s %s %s\n' "$$" installer "$(date +%s 2>/dev/null || date)" > "$INSTALLER_ACTION_LOCK_FILE") 2>/dev/null; then
		installer_mutation_lock_release
		return 1
	fi

	installer_mutation_lock_owned=1
}

installer_mutation_lock_release() {
	if [ -d "$INSTALLER_ACTION_LOCK_DIR" ]; then
		pid="$(awk 'NR == 1 {print $1}' "$INSTALLER_ACTION_LOCK_DIR/owner" 2>/dev/null)"
		if [ "$pid" = "$$" ]; then
			rm -f "$INSTALLER_ACTION_LOCK_DIR/owner"
			rmdir "$INSTALLER_ACTION_LOCK_DIR" 2>/dev/null || true
		fi
	fi

	if [ -e "$INSTALLER_ACTION_LOCK_FILE" ]; then
		pid="$(awk 'NR == 1 {print $1}' "$INSTALLER_ACTION_LOCK_FILE" 2>/dev/null)"
		[ "$pid" = "$$" ] && rm -f "$INSTALLER_ACTION_LOCK_FILE"
	fi
	installer_mutation_lock_owned=0
}

installer_exit_handler() {
	exit_status="$1"
	trap - EXIT INT TERM HUP
	set +e

	if [ "$exit_status" -ne 0 ]; then
		if [ "${transaction_phase:-}" = "official_update" ]; then
			restore_missing_persistent_paths "${persistent_backup_dir:-}" ||
				log "ERROR: restoring missing persistent Podkop state after interrupted official update failed${backup_dir:+; persistent backup: $backup_dir}"
		else
			restore_if_needed
		fi
	fi
	installer_mutation_lock_release

	if [ -n "${tmp_dir:-}" ]; then
		rm -rf "$tmp_dir"
	fi

	exit "$exit_status"
}

installer_signal_handler() {
	installer_exit_handler "$1"
}

abort_with_restore() {
	restore_if_needed
	fail "$1"
}

has_latest_subscription_backend() {
	count="$(grep -c "PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload" /usr/bin/podkop 2>/dev/null || true)"
	[ "${count:-0}" -ge 3 ] &&
		grep -q '^case "\$1" in' /usr/bin/podkop 2>/dev/null &&
		grep -q "get_subscription_items_cached" /usr/bin/podkop 2>/dev/null &&
		grep -q "set_subscription_links_enabled" /usr/bin/podkop 2>/dev/null &&
		grep -q "set_subscription_sections_enabled" /usr/bin/podkop 2>/dev/null &&
		grep -q '^set_subscription_sections_enabled)' /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_apply_v2" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_update_json" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_speedtest" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_patch_update" /usr/bin/podkop 2>/dev/null &&
		grep -q "get_subscription_patch_update_status" /usr/bin/podkop 2>/dev/null &&
		grep -q 'run_with_timeout 900 env PODKOP_PATCH_VERSION=' /usr/bin/podkop 2>/dev/null &&
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
		grep -q "fakeip_router_dns_truth_v4" /usr/bin/podkop 2>/dev/null &&
		grep -q 'subscription_speedtest "$2" "$3"' /usr/bin/podkop 2>/dev/null &&
		grep -q -- '--arg state "running" --arg message "speedtest_running"' /usr/bin/podkop 2>/dev/null &&
		! grep -q "wget -T 30 -t" /usr/bin/podkop 2>/dev/null &&
		! grep -q "wget -T 30 -t" /usr/lib/podkop/helpers.sh 2>/dev/null
}

has_install_marker() {
	grep -Fxq "# $INSTALL_MARKER" /usr/bin/podkop 2>/dev/null
}

mark_latest_subscription_backend() {
	grep -Fxq "# $INSTALL_MARKER" /usr/bin/podkop 2>/dev/null && return 0
	printf '\n# %s\n' "$INSTALL_MARKER" >> /usr/bin/podkop
}

decode_lmo_asset() {
	if [ -s "$tmp_dir/$LMO_DECODED_FILE" ]; then
		return 0
	fi

	tr -d '\r\n\t ' < "$tmp_dir/$LMO_FILE" | base64 -d > "$tmp_dir/$LMO_DECODED_FILE"
}

prepare_versioned_luci_assets() {
	case "$LUCI_MODULE_NAMESPACE" in
		"" | *[!A-Za-z0-9_]*)
			return 1
			;;
	esac

	versioned_tmp_dir="$tmp_dir/luci-versioned/$LUCI_MODULE_NAMESPACE"
	rm -rf "$versioned_tmp_dir"
	mkdir -p "$versioned_tmp_dir" || return 1

	for asset in main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
		[ -s "$tmp_dir/$asset" ] || return 1
		sed "s/require view\\.podkop\\./require view.$LUCI_MODULE_NAMESPACE./g" \
			"$tmp_dir/$asset" > "$versioned_tmp_dir/$asset" || return 1
		[ -s "$versioned_tmp_dir/$asset" ] || return 1
	done
}

base_luci_assets_current() {
	for asset in main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
		[ -f "$LUCI_VIEW_ROOT/podkop/$asset" ] || return 1
		cmp -s "$LUCI_VIEW_ROOT/podkop/$asset" "$tmp_dir/$asset" || return 1
	done
}

versioned_luci_assets_current() {
	versioned_tmp_dir="$tmp_dir/luci-versioned/$LUCI_MODULE_NAMESPACE"
	versioned_view_dir="$LUCI_VIEW_ROOT/$LUCI_MODULE_NAMESPACE"

	for asset in main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
		[ -f "$versioned_view_dir/$asset" ] || return 1
		cmp -s "$versioned_view_dir/$asset" "$versioned_tmp_dir/$asset" || return 1
	done

	[ -f "$LUCI_MENU_FILE" ] || return 1
	jq -e --arg path "$LUCI_MODULE_ENTRY" \
		'.["admin/services/podkop"].action.type == "view" and .["admin/services/podkop"].action.path == $path' \
		"$LUCI_MENU_FILE" >/dev/null 2>&1
}

dns_optimizer_has_google_play_guard() {
	optimizer_file="$1"

	[ -s "$optimizer_file" ] &&
		grep -Fxq "GOOGLE_PLAY_GUARD_CAPABILITY=\"$DNS_OPTIMIZER_GOOGLE_PLAY_GUARD_CAPABILITY\"" "$optimizer_file" &&
		grep -Fxq "CHATGPT_GUARD_CAPABILITY=\"$DNS_OPTIMIZER_CHATGPT_GUARD_CAPABILITY\"" "$optimizer_file" &&
		grep -q '^validate_google_play_transport() {' "$optimizer_file" &&
		grep -q '^validate_chatgpt_transport() {' "$optimizer_file"
}

install_versioned_luci_assets() {
	versioned_tmp_dir="$tmp_dir/luci-versioned/$LUCI_MODULE_NAMESPACE"
	versioned_view_dir="$LUCI_VIEW_ROOT/$LUCI_MODULE_NAMESPACE"
	menu_tmp="$tmp_dir/luci-app-podkop.menu.json"

	[ -f "$LUCI_MENU_FILE" ] || abort_with_restore "Podkop LuCI menu is missing"
	mkdir -p "$LUCI_VIEW_ROOT/podkop" "$versioned_view_dir" "$(dirname "$LUCI_MENU_FILE")" ||
		abort_with_restore "failed to create Podkop LuCI asset directories"

	for asset in main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
		cp "$tmp_dir/$asset" "$LUCI_VIEW_ROOT/podkop/$asset" ||
			abort_with_restore "failed to install Podkop LuCI asset: $asset"
		cp "$versioned_tmp_dir/$asset" "$versioned_view_dir/$asset" ||
			abort_with_restore "failed to install versioned Podkop LuCI asset: $asset"
		chmod 644 "$LUCI_VIEW_ROOT/podkop/$asset" "$versioned_view_dir/$asset"
	done

	jq --arg path "$LUCI_MODULE_ENTRY" \
		'.["admin/services/podkop"].action = {"type":"view","path":$path}' \
		"$LUCI_MENU_FILE" > "$menu_tmp" || abort_with_restore "failed to version Podkop LuCI menu"
	jq -e . "$menu_tmp" >/dev/null 2>&1 || abort_with_restore "Podkop LuCI menu validation failed"
	cp "$menu_tmp" "$LUCI_MENU_FILE" || abort_with_restore "failed to install Podkop LuCI menu"
	chmod 644 "$LUCI_MENU_FILE"
}

luci_assets_current() {
	decode_lmo_asset || return 1

	base_luci_assets_current &&
		versioned_luci_assets_current &&
		[ -x /usr/bin/podkop-dns-optimizer ] &&
		dns_optimizer_has_google_play_guard /usr/bin/podkop-dns-optimizer &&
		cmp -s /usr/bin/podkop-dns-optimizer "$tmp_dir/$DNS_OPTIMIZER_FILE" &&
		[ -x /usr/bin/podkop-dns-failover ] &&
		cmp -s /usr/bin/podkop-dns-failover "$tmp_dir/$DNS_FAILOVER_FILE" &&
		[ -x /etc/init.d/podkop-dns-failover ] &&
		cmp -s /etc/init.d/podkop-dns-failover "$tmp_dir/$DNS_FAILOVER_INIT_FILE" &&
		grep -q '^load_active_dns_settings() {' /usr/bin/podkop 2>/dev/null &&
		[ -x /usr/bin/podkop-update-manager ] &&
		cmp -s /usr/bin/podkop-update-manager "$tmp_dir/$UPDATE_MANAGER_FILE" &&
		jq -e '.["luci-app-podkop"].read.file["/usr/bin/podkop-dns-optimizer"] == ["exec"]' /usr/share/rpcd/acl.d/luci-app-podkop.json >/dev/null 2>&1 &&
		jq -e '.["luci-app-podkop"].read.file["/usr/bin/podkop-update-manager"] == ["exec"]' /usr/share/rpcd/acl.d/luci-app-podkop.json >/dev/null 2>&1 &&
		[ -f /usr/lib/lua/luci/i18n/podkop.ru.lmo ] &&
		cmp -s /usr/lib/lua/luci/i18n/podkop.ru.lmo "$tmp_dir/$LMO_DECODED_FILE"
}

ensure_dns_optimizer_acl() {
	acl_file="/usr/share/rpcd/acl.d/luci-app-podkop.json"
	acl_tmp="$tmp_dir/luci-app-podkop.json"

	[ -f "$acl_file" ] || abort_with_restore "Podkop RPC ACL is missing"
	jq '.["luci-app-podkop"].read.file["/usr/bin/podkop-dns-optimizer"] = ["exec"] | .["luci-app-podkop"].read.file["/usr/bin/podkop-update-manager"] = ["exec"]' "$acl_file" > "$acl_tmp" ||
		abort_with_restore "failed to update Podkop RPC ACL"
	jq -e . "$acl_tmp" >/dev/null 2>&1 || abort_with_restore "Podkop RPC ACL validation failed"
	cp "$acl_tmp" "$acl_file" || abort_with_restore "failed to install Podkop RPC ACL"
	chmod 644 "$acl_file"
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
    set_subscription_sections_enabled
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
set_subscription_sections_enabled)
    set_subscription_sections_enabled "$2"
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

needs_prebuilt_0720_runtime() {
	/usr/bin/podkop show_version 2>/dev/null | grep -Eq "^v?0\\.7\\.20$" || return 1

	grep -q "subscription_mix_manual_links_v1" /usr/bin/podkop 2>/dev/null &&
		grep -q "subscription_urltest)" /usr/bin/podkop 2>/dev/null &&
		grep -q "collect_urltest_proxy_links" /usr/bin/podkop 2>/dev/null &&
		grep -q "patch_update_noop_v1" /usr/bin/podkop 2>/dev/null &&
		return 1

	return 0
}

normalize_version() {
	printf '%s\n' "$1" | sed 's/^v//' | awk -F. '{ printf "%d %d %d\n", $1, $2, $3 }'
}

is_semver() {
	case "$1" in
	[0-9]*.[0-9]*.[0-9]*)
		return 0
		;;
	esac

	return 1
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

podkop_version_supported() {
	version="$1"
	for supported_version in $PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS; do
		[ "$version" = "$supported_version" ] && return 0
	done
	return 1
}

current_podkop_version() {
	/usr/bin/podkop show_version 2>/dev/null | sed 's/^v//' || true
}

installed_package_version() {
	pkg="$1"
	if command -v apk >/dev/null 2>&1; then
		apk info -e "$pkg" >/dev/null 2>&1 || return 1
		apk list --installed --manifest 2>/dev/null | awk -v pkg="$pkg" '
			$1 == pkg && NF >= 2 { print $2; found=1; exit }
			END { if (!found) exit 1 }
		'
		return
	fi
	if command -v opkg >/dev/null 2>&1; then
		opkg status "$pkg" 2>/dev/null | awk -v pkg="$pkg" '
			$1 == "Package:" { match_pkg=($2 == pkg) }
			match_pkg && $1 == "Version:" { version=$2 }
			match_pkg && $1 == "Status:" && $NF == "installed" { installed=1 }
			END { if (match_pkg && installed && version != "") print version; else exit 1 }
		'
		return
	fi
	return 1
}

package_version_core() {
	package_version="$1"
	package_version="${package_version#v}"
	printf '%s\n' "${package_version%%-*}"
}

podkop_package_generation() {
	podkop_package="$(installed_package_version podkop)" || return 1
	luci_package="$(installed_package_version luci-app-podkop)" || return 1
	if command -v apk >/dev/null 2>&1; then
		package_manager="apk"
	elif command -v opkg >/dev/null 2>&1; then
		package_manager="opkg"
	else
		return 1
	fi
	printf '%s|podkop=%s|luci-app-podkop=%s\n' "$package_manager" "$podkop_package" "$luci_package"
}

podkop_packages_match_runtime() {
	expected_version="$1"
	podkop_package="$(installed_package_version podkop)" || return 1
	luci_package="$(installed_package_version luci-app-podkop)" || return 1
	podkop_package_core="$(package_version_core "$podkop_package")"
	luci_package_core="$(package_version_core "$luci_package")"
	[ "$podkop_package" = "$luci_package" ] &&
		[ "$podkop_package_core" = "$expected_version" ] &&
		[ "$luci_package_core" = "$expected_version" ]
}

podkop_config_exists() {
	[ -e /etc/config/podkop ]
}

ensure_no_pending_uci_changes() {
	command -v uci >/dev/null 2>&1 || return 1
	pending_changes="$(uci changes 2>/dev/null)" || return 1
	[ -z "$pending_changes" ]
}

ensure_no_pending_podkop_changes() {
	command -v uci >/dev/null 2>&1 || return 1
	if pending_changes="$(uci changes podkop 2>/dev/null)"; then
		[ -z "$pending_changes" ]
		return
	fi
	! podkop_config_exists
	return
}

podkop_runtime_exists() {
	[ -x /usr/bin/podkop ]
}

podkop_persistent_state_exists() {
	[ -e /etc/config/podkop ] || [ -e /etc/podkop ]
}

run_official_podkop_installer() {
	official_installer="$1"

	# The official installer can ask first about removing https-dns-proxy and
	# then about its optional Russian translation. Our own translation is
	# installed below, so make the unified command deterministic without a TTY.
	printf 'yes\nn\n' | sh "$official_installer"
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

	if is_semver "$version"; then
		printf '%s\n' "$version"
		return 0
	fi

	return 1
}

update_manager_v1_requested_podkop_upgrade() {
	state_dir="/tmp/podkop-update-manager"
	[ "$PODKOP_PATCH_UPDATE_PODKOP_WAS_SET" = "1" ] || return 1
	[ "$PODKOP_PATCH_UPDATE_PODKOP" = "1" ] || return 1
	[ "$PODKOP_PATCH_FORCE_PODKOP_UPDATE_WAS_SET" = "0" ] || return 1
	[ "$0" = "$state_dir/installer.sh" ] || return 1
	[ -r "$state_dir/lock/pid" ] || return 1
	[ "$(cat "$state_dir/lock/pid" 2>/dev/null)" = "$PPID" ] || return 1
	jq -e '.updateMode == "podkop_and_patch" and .podkopUpdateAvailable == true and .canUpdate == true' \
		"$state_dir/details.json" >/dev/null 2>&1
}

update_official_podkop_if_requested() {
	[ "${PODKOP_PATCH_UPDATE_PODKOP:-1}" = "1" ] || return 0
	force_podkop_update="${PODKOP_PATCH_FORCE_PODKOP_UPDATE:-0}"
	podkop_was_installed=0
	podkop_runtime_exists && podkop_was_installed=1
	if [ "$force_podkop_update" != "1" ] && update_manager_v1_requested_podkop_upgrade; then
		force_podkop_update=1
		log "Continuing the combined update requested by the installed update center."
	fi

	current_version="$(current_podkop_version)"
	if podkop_runtime_exists && ! is_semver "$current_version"; then
		fail "installed Podkop version is unknown ('$current_version'); automatic update is not supported because official Podkop may require interactive config migration"
	fi

	if [ -n "$current_version" ] && ! version_ge "$current_version" "0.7.0"; then
		fail "installed Podkop $current_version is older than 0.7.0; automatic update is not supported because official Podkop may require interactive config migration"
	fi

	target_version="$PODKOP_PATCH_TARGET_PODKOP_VERSION"
	latest_version="$(latest_official_podkop_version || true)"

	if [ -n "$latest_version" ] && version_ge "$latest_version" "$target_version"; then
		if podkop_version_supported "$latest_version"; then
			target_version="$latest_version"
			log "Latest official Podkop version: $target_version"
		elif [ -n "$current_version" ] && podkop_version_supported "$current_version"; then
			log "Latest official Podkop $latest_version is not supported by this patch. Keeping Podkop $current_version."
			return 0
		else
			fail "latest official Podkop $latest_version is not supported by this patch; supported versions: $PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS"
		fi
	else
		log "Could not detect a newer official Podkop release; target is $target_version."
	fi

	if [ "$force_podkop_update" != "1" ] &&
		[ -n "$current_version" ] && podkop_version_supported "$current_version"; then
		if version_ge "$current_version" "$target_version"; then
			log "Official Podkop is already $current_version; target is $target_version. Skipping official update."
		else
			log "Installed Podkop $current_version is supported by this patch; keeping it instead of performing a risky automatic package upgrade to $target_version."
			log "Use the update center after installation, or set PODKOP_PATCH_FORCE_PODKOP_UPDATE=1 to request an explicit official Podkop upgrade."
		fi
		return 0
	fi

	official_installer="$tmp_dir/podkop-official-install.sh"
	download "$PODKOP_OFFICIAL_INSTALL_URL" "$official_installer"
	ensure_no_pending_uci_changes ||
		fail "the router has pending or unreadable UCI changes; apply or revert them before the official Podkop update"
	ensure_no_pending_podkop_changes ||
		fail "Podkop UCI state changed or became unreadable before the official update; apply or revert pending changes and retry"

	if podkop_persistent_state_exists; then
		backup_persistent_paths
	fi
	transaction_phase="official_update"

	if [ "$podkop_was_installed" = "1" ]; then
		log "Updating official Podkop before applying Subscription URLTest patch."
	else
		log "Installing official Podkop before applying Subscription URLTest patch."
	fi
	if ! run_official_podkop_installer "$official_installer"; then
		if [ "$podkop_was_installed" = "1" ]; then
			reject_official_podkop_result "official Podkop update failed; package state may have changed, so the patch was not applied"
		fi

		reject_official_podkop_result "official Podkop installation failed; package state may be partial, so the patch was not applied"
	fi

	podkop_runtime_exists || reject_official_podkop_result "Official Podkop installer finished, but /usr/bin/podkop is missing"
	current_version="$(current_podkop_version)"
	if ! podkop_version_supported "$current_version"; then
		reject_official_podkop_result "official Podkop installed unsupported version $current_version; Subscription URLTest patch was not applied"
	fi
	if ! version_ge "$current_version" "$target_version"; then
		reject_official_podkop_result "official Podkop installer finished with version $current_version below target $target_version; Subscription URLTest patch was not applied"
	fi
	podkop_packages_match_runtime "$current_version" ||
		reject_official_podkop_result "official Podkop installer did not install matching podkop and luci-app-podkop packages for version $current_version; Subscription URLTest patch was not applied"
	restore_missing_persistent_paths "$persistent_backup_dir" ||
		fail "official Podkop was installed, but restoring missing persistent Podkop state failed${backup_dir:+; persistent backup: $backup_dir}"
}

tmp_dir="$(mktemp -d)"
backup_dir=""
persistent_backup_dir=""
rollback_dir=""
rollback_generation=""
dns_failover_service_state="unknown"
backup_complete=0
restore_on_fail=0
restore_done=0
transaction_phase="preflight"
light_reload=0
installer_mutation_lock_owned=0
trap 'installer_exit_handler "$?"' EXIT
trap 'installer_signal_handler 130' INT
trap 'installer_signal_handler 143' TERM
trap 'installer_signal_handler 129' HUP

command -v base64 >/dev/null 2>&1 || fail "base64 utility is required"
command -v jq >/dev/null 2>&1 || fail "jq utility is required"

installer_mutation_lock_acquire || fail "another Podkop change is already running; retry after it finishes"

ensure_no_pending_uci_changes || fail "the router has pending or unreadable UCI changes; apply or revert them before updating Podkop or the patch"
ensure_no_pending_podkop_changes || fail "Podkop has pending UCI changes; apply or revert them before updating Podkop or the patch"
require_patch
prefetch_patch_assets
dns_optimizer_has_google_play_guard "$tmp_dir/$DNS_OPTIMIZER_FILE" ||
	fail "downloaded DNS optimizer lacks the Google Play or ChatGPT/OpenAI guard capability"
prepare_versioned_luci_assets || fail "failed to prepare versioned Podkop LuCI assets"
update_official_podkop_if_requested
ensure_no_pending_uci_changes || fail "the router UCI state changed or became unreadable before patching; apply or revert pending changes and retry"
ensure_no_pending_podkop_changes || fail "Podkop UCI state changed or became unreadable before patching; apply or revert pending changes and retry"
transaction_phase="prepatch"

[ -x /usr/bin/podkop ] || fail "Podkop is not installed at /usr/bin/podkop"

if [ "${PODKOP_PATCH_FORCE:-0}" != "1" ] && has_install_marker && has_latest_subscription_backend && luci_assets_current; then
	transaction_phase="committed"
	restore_on_fail=0
	log "Subscription URLTest patch is already up to date; nothing to do."
	log "PODKOP_PATCH_NOOP=1"
	[ -z "$backup_dir" ] || log "Persistent backup saved at: $backup_dir"
	cleanup_old_backups
	exit 0
fi

if has_latest_subscription_backend; then
	log "Subscription URLTest backend is already up to date; refreshing LuCI files."
	backup_runtime
	light_reload=1
elif needs_prebuilt_0720_runtime; then
	log "Installing Subscription URLTest runtime for Podkop 0.7.20."
	backup_runtime
	rm -f "$LUCI_VIEW_ROOT/podkop/subscriptions.js"

	if ! install_prebuilt_0720_runtime; then
		abort_with_restore "runtime install failed"
	fi
elif has_cache_only_subscription_backend; then
	log "Subscription URLTest backend is installed; applying speedtest maintenance upgrade."
	backup_runtime
	light_reload=1
elif has_subscription_backend; then
	log "Subscription URLTest backend is installed; applying maintenance upgrade."
	backup_runtime
	light_reload=1
elif has_actions_subscription_backend; then
	backup_runtime

	if ! sh "$tmp_dir/$UI_FIX_BACKEND_FILE"; then
		abort_with_restore "runtime UI fix backend upgrade failed"
	fi
elif has_batch_subscription_backend; then
	backup_runtime

	if ! apply_runtime_patch "$tmp_dir/$ACTIONS_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime actions upgrade patch failed"
	fi
elif has_legacy_subscription_backend; then
	backup_runtime

	if ! apply_runtime_patch "$tmp_dir/$LEGACY_UPGRADE_PATCH_FILE"; then
		abort_with_restore "runtime legacy upgrade patch failed"
	fi
elif has_v0719_package_backend; then
	backup_runtime

	if ! apply_runtime_patch "$tmp_dir/$V0719_PATCH_FILE"; then
		abort_with_restore "runtime v0.7.19 patch failed"
	fi
else
	backup_runtime
	rm -f "$LUCI_VIEW_ROOT/podkop/subscriptions.js"

	if ! install_prebuilt_0720_runtime; then
		abort_with_restore "runtime install failed"
	fi
fi

migration_status=0
migrate_dns_optimizer_candidate_defaults || migration_status=$?
case "$migration_status" in
	0) ;;
	2) abort_with_restore "Podkop has pending UCI changes; apply or revert them before updating the patch" ;;
	*) abort_with_restore "failed to migrate stock DNS optimizer selections" ;;
esac

if { ! has_latest_subscription_backend || ! has_install_marker; } && has_subscription_backend; then
	if ! sh "$tmp_dir/$MAINTENANCE_UPGRADE_FILE"; then
		abort_with_restore "runtime maintenance upgrade failed"
	fi
fi

if ! grep -q '^subscription_patch_update_check() {' /usr/bin/podkop 2>/dev/null ||
	! grep -q '^get_subscription_patch_update_log() {' /usr/bin/podkop 2>/dev/null; then
	if ! sh "$tmp_dir/$UPDATE_CENTER_UPGRADE_FILE"; then
		abort_with_restore "runtime update center upgrade failed"
	fi
fi

if ! grep -q '^load_active_dns_settings() {' /usr/bin/podkop 2>/dev/null; then
	if ! sh "$tmp_dir/$DNS_FAILOVER_UPGRADE_FILE"; then
		abort_with_restore "DNS failover runtime upgrade failed"
	fi
fi

if ! grep -q '^set_subscription_sections_enabled() {' /usr/bin/podkop 2>/dev/null ||
	! grep -q '^set_subscription_sections_enabled)' /usr/bin/podkop 2>/dev/null ||
	! grep -q 'subscription_apply_v2' /usr/bin/podkop 2>/dev/null; then
	apply_v2_source="$tmp_dir/podkop.subscription-apply-v2-source"
	cp "$tmp_dir/podkop.runtime-0.7.20" "$apply_v2_source" || abort_with_restore "failed to prepare subscription apply v2 source"
	if ! PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$apply_v2_source" \
		sh "$tmp_dir/$APPLY_V2_UPGRADE_FILE"; then
		abort_with_restore "subscription apply v2 runtime upgrade failed"
	fi
fi

for runtime_file in /usr/bin/podkop /usr/lib/podkop/helpers.sh; do
	if [ -f "$runtime_file" ]; then
		sed -i 's/wget -T 30 -t 1 /wget -T 30 /g' "$runtime_file"
	fi
done

if [ -f /usr/bin/podkop ]; then
	sed -i 's/run_with_timeout 240 env PODKOP_PATCH_VERSION=/run_with_timeout 900 env PODKOP_PATCH_VERSION=/g' /usr/bin/podkop
	grep -q 'run_with_timeout 900 env PODKOP_PATCH_VERSION=' /usr/bin/podkop 2>/dev/null ||
		abort_with_restore "subscription patch update timeout upgrade failed"
fi

if [ -f /usr/bin/podkop ]; then
	sed -i 's#CLASH_URL="$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT"#CLASH_URL="http://$clash_api_controller_address:$SB_CLASH_API_CONTROLLER_PORT"#g' /usr/bin/podkop
	ensure_podkop_dispatcher /usr/bin/podkop
	grep -q '^set_subscription_sections_enabled() {' /usr/bin/podkop 2>/dev/null ||
		abort_with_restore "subscription apply v2 capability check failed"
	grep -q '^set_subscription_sections_enabled)' /usr/bin/podkop 2>/dev/null ||
		abort_with_restore "subscription apply v2 dispatcher check failed"
	grep -q 'subscription_apply_v2' /usr/bin/podkop 2>/dev/null ||
		abort_with_restore "subscription apply v2 marker check failed"
	mark_latest_subscription_backend || abort_with_restore "failed to write subscription patch release marker"
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

mkdir -p "$LUCI_VIEW_ROOT/podkop" /etc/init.d
install_versioned_luci_assets
base_luci_assets_current && versioned_luci_assets_current ||
	abort_with_restore "versioned Podkop LuCI asset verification failed"
cp "$tmp_dir/$DNS_OPTIMIZER_FILE" /usr/bin/podkop-dns-optimizer
cp "$tmp_dir/$DNS_FAILOVER_FILE" /usr/bin/podkop-dns-failover
cp "$tmp_dir/$DNS_FAILOVER_INIT_FILE" /etc/init.d/podkop-dns-failover
cp "$tmp_dir/$UPDATE_MANAGER_FILE" /usr/bin/podkop-update-manager
ensure_dns_optimizer_acl

mkdir -p /usr/lib/lua/luci/i18n
if ! decode_lmo_asset; then
	abort_with_restore "failed to install LuCI translation"
fi
cp "$tmp_dir/$LMO_DECODED_FILE" /usr/lib/lua/luci/i18n/podkop.ru.lmo || abort_with_restore "failed to install LuCI translation"

chmod 755 /usr/bin/podkop
chmod 755 /usr/bin/podkop-dns-optimizer
chmod 755 /usr/bin/podkop-dns-failover
chmod 755 /etc/init.d/podkop-dns-failover
chmod 755 /usr/bin/podkop-update-manager
[ -f /usr/lib/podkop/sing_box_config_facade.sh ] && chmod 644 /usr/lib/podkop/sing_box_config_facade.sh
chmod 644 /usr/lib/lua/luci/i18n/podkop.ru.lmo

ensure_podkop_dispatcher /usr/bin/podkop

if ! ash -n /usr/bin/podkop; then
	abort_with_restore "podkop syntax check failed"
fi

if ! ash -n /usr/bin/podkop-dns-optimizer; then
	abort_with_restore "DNS optimizer syntax check failed"
fi

if ! ash -n /usr/bin/podkop-dns-failover || ! ash -n /etc/init.d/podkop-dns-failover; then
	abort_with_restore "DNS failover syntax check failed"
fi

if ! ash -n /usr/bin/podkop-update-manager; then
	abort_with_restore "update manager syntax check failed"
fi

if [ "$(/usr/bin/podkop-dns-optimizer version 2>/dev/null || true)" != "$DNS_OPTIMIZER_VERSION" ]; then
	abort_with_restore "DNS optimizer version check failed"
fi

dns_optimizer_has_google_play_guard /usr/bin/podkop-dns-optimizer ||
	abort_with_restore "DNS optimizer Google Play or ChatGPT/OpenAI guard capability check failed"

if [ "$(/usr/bin/podkop-dns-failover version 2>/dev/null || true)" != "$DNS_FAILOVER_VERSION" ]; then
	abort_with_restore "DNS failover version check failed"
fi

if [ "$(/usr/bin/podkop-update-manager version 2>/dev/null || true)" != "$UPDATE_MANAGER_VERSION" ]; then
	abort_with_restore "update manager version check failed"
fi

if [ -z "$(/usr/bin/podkop show_version 2>/dev/null)" ]; then
	abort_with_restore "podkop command dispatcher check failed"
fi

has_install_marker || abort_with_restore "subscription patch release marker verification failed"

if [ -f /usr/lib/podkop/sing_box_config_facade.sh ] && ! ash -n /usr/lib/podkop/sing_box_config_facade.sh; then
	abort_with_restore "sing-box facade syntax check failed"
fi

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true

if [ -x /etc/init.d/podkop ]; then
	if [ "$light_reload" -eq 1 ] && podkop_dnsmasq_configured; then
		reload_command="PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload"
	else
		reload_command="PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop restart"
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

/etc/init.d/podkop-dns-failover enable >/dev/null 2>&1 || abort_with_restore "failed to enable DNS failover service"
/etc/init.d/podkop-dns-failover restart >/dev/null 2>&1 || abort_with_restore "failed to restart DNS failover service"

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

transaction_phase="committed"
restore_on_fail=0
log "Installed Subscription URLTest patch."
log "Backup saved at: $backup_dir"
cleanup_old_backups
