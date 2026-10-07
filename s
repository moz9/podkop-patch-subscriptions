#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-podkop-pe}"
RAW_ROOT="${PODKOP_PATCH_RAW_ROOT:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PATCH_VERSION}"
RAW_BASE="$RAW_ROOT/openwrt"
WORK_DIR="${PODKOP_PATCH_SAFE_WORK_DIR:-/tmp/podkop-patch-safe-update}"
ASSET_DIR="$WORK_DIR/openwrt"
INSTALLER="$WORK_DIR/i"
RUNNER="$WORK_DIR/run.sh"
LOG_FILE="${PODKOP_PATCH_SAFE_LOG:-/tmp/podkop-patch-safe-update.log}"
STATUS_FILE="${PODKOP_PATCH_SAFE_STATUS:-/tmp/podkop-patch-safe-update.status}"
PID_FILE="${PODKOP_PATCH_SAFE_PID:-/tmp/podkop-patch-safe-update.pid}"

log() {
	printf '%s\n' "$*"
}

fail() {
	log "ERROR: $*" >&2
	printf 'failed %s reason=%s\n' "$(date +%s 2>/dev/null || date)" "$*" > "$STATUS_FILE" 2>/dev/null || true
	exit 1
}

download() {
	url="$1"
	out="$2"
	ok=0
	raw_host=""

	case "$url" in
		*raw.githubusercontent.com*)
			raw_host="raw.githubusercontent.com"
			;;
	esac

	mkdir -p "$(dirname "$out")"
	case "$url" in
		file://*)
			local_path="${url#file://}"
			local_path="${local_path%%\?*}"
			[ -s "$local_path" ] || fail "local source not found: $local_path"
			cp "$local_path" "$out" || fail "failed to copy $local_path"
			return 0
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		if curl -fsSL --connect-timeout 10 -m 40 "$url" -o "$out"; then
			ok=1
		elif [ "$raw_host" = "raw.githubusercontent.com" ]; then
			for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
				if curl -fsSL --connect-timeout 10 -m 40 \
					--resolve "raw.githubusercontent.com:443:$ip" \
					"$url" -o "$out"; then
					ok=1
					break
				fi
			done
		fi
	fi

	if [ "$ok" -ne 1 ] && command -v wget >/dev/null 2>&1; then
		if wget -T 40 -O "$out" "$url"; then
			ok=1
		fi
	fi

	[ "$ok" -eq 1 ] && [ -s "$out" ] || fail "failed to download $url"
}

fetch_asset() {
	rel="$1"
	download "$RAW_BASE/$rel?t=$(date +%s)" "$ASSET_DIR/$rel"
	verify_release_file "openwrt/$rel" "$ASSET_DIR/$rel"
}

verify_release_file() {
	file_expected="$(jq -er --arg path "$1" '.sha256[$path] | select(type == "string" and length == 64)' "$MANIFEST")" ||
		fail "release checksum is missing for $1"
	case "$file_expected" in *[!0123456789abcdef]*) fail "release checksum is invalid for $1" ;; esac
	file_actual="$(sha256sum "$2" | awk '{print $1}')" || fail "cannot checksum $1"
	[ "$file_actual" = "$file_expected" ] || fail "release checksum mismatch for $1"
}

# Fetch only known files; never recursively delete a caller-supplied directory.
mkdir -p "$ASSET_DIR"
: > "$LOG_FILE"
printf 'prefetch %s\n' "$(date +%s 2>/dev/null || date)" > "$STATUS_FILE"

command -v jq >/dev/null 2>&1 || fail "jq utility is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum utility is required"
MANIFEST="$ASSET_DIR/update-manifest.json"
download "$RAW_BASE/update-manifest.json?t=$(date +%s)" "$MANIFEST"
jq -e '.schemaVersion == 1 and .channel == "podkop-pe" and (.patchVersion | type == "string") and (.sha256 | type == "object")' "$MANIFEST" >/dev/null ||
	fail "invalid release manifest"
download "$RAW_ROOT/i?t=$(date +%s)" "$INSTALLER"
verify_release_file i "$INSTALLER"
chmod 755 "$INSTALLER"

for rel in \
	podkop.ru.lmo.base64 \
	subscriptions.js \
	main.js \
	section.js \
	settings.js \
	dashboard.js \
	diagnostic.js \
	podkop.js \
	podkop-dns-optimizer \
	podkop-dns-benchmark \
	dns_benchmark.js \
	dns-main.json \
	dns-bootstrap.json \
	podkop-dns-failover \
	podkop-dns-failover.init \
	podkop-dns-failover-upgrade.sh \
	podkop-subscription-apply-v2-upgrade.sh \
	podkop-subscription-sources-upgrade.sh \
	podkop-subscription-seamless-reload-upgrade.sh \
	podkop-update-manager \
	podkop-subscription-maintenance-upgrade.sh \
	podkop-update-center-upgrade.sh \
	podkop-subscription-v0719-runtime.patch \
	podkop-subscription-actions-upgrade.patch \
	podkop-subscription-legacy-upgrade.patch \
	podkop-actions-ui-fix.sh \
	runtime-0.7.23/usr/bin/podkop \
	runtime-0.7.23/www/luci-static/resources/view/podkop/podkop.js \
	runtime-0.7.23/usr/lib/podkop/helpers.sh \
	runtime-0.7.23/usr/lib/podkop/sing_box_config_facade.sh \
	runtime-0.7.23/usr/lib/podkop/sing_box_config_manager.sh
do
	fetch_asset "$rel"
done

cat > "$RUNNER" <<EOF
#!/bin/sh
set +e
exec >> "$LOG_FILE" 2>&1
printf 'running %s\\n' "\$(date +%s 2>/dev/null || date)" > "$STATUS_FILE"
PODKOP_PATCH_RAW_BASE="file://$ASSET_DIR" sh "$INSTALLER"
rc=\$?
if [ "\$rc" -eq 0 ]; then
	printf 'ok %s\\n' "\$(date +%s 2>/dev/null || date)" > "$STATUS_FILE"
else
	printf 'failed %s rc=%s\\n' "\$(date +%s 2>/dev/null || date)" "\$rc" > "$STATUS_FILE"
fi
exit "\$rc"
EOF
chmod 755 "$RUNNER"

if [ "${PODKOP_PATCH_SAFE_FOREGROUND:-0}" = "1" ]; then
	sh "$RUNNER"
	exit $?
fi

if command -v nohup >/dev/null 2>&1; then
	nohup sh "$RUNNER" >/dev/null 2>&1 </dev/null &
else
	sh "$RUNNER" >/dev/null 2>&1 </dev/null &
fi
echo "$!" > "$PID_FILE"
printf 'started pid=%s\n' "$(cat "$PID_FILE")"
printf 'log=%s\n' "$LOG_FILE"
printf 'status=%s\n' "$STATUS_FILE"
