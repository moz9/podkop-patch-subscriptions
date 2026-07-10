#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-main}"
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
		if wget --no-check-certificate -T 40 -O "$out" "$url"; then
			ok=1
		elif [ "$raw_host" = "raw.githubusercontent.com" ]; then
			clean_path="${url#https://raw.githubusercontent.com/}"
			clean_path="${clean_path%%\?*}"
			for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
				if wget --no-check-certificate -T 40 \
					--header="Host: raw.githubusercontent.com" \
					-O "$out" "https://$ip/$clean_path"; then
					ok=1
					break
				fi
			done
		fi
	fi

	[ "$ok" -eq 1 ] && [ -s "$out" ] || fail "failed to download $url"
}

fetch_asset() {
	rel="$1"
	download "$RAW_BASE/$rel?t=$(date +%s)" "$ASSET_DIR/$rel"
}

rm -rf "$WORK_DIR"
mkdir -p "$ASSET_DIR"
: > "$LOG_FILE"
printf 'prefetch %s\n' "$(date +%s 2>/dev/null || date)" > "$STATUS_FILE"

download "$RAW_ROOT/i?t=$(date +%s)" "$INSTALLER"
chmod 755 "$INSTALLER"

for rel in \
	podkop.ru.lmo.base64 \
	subscriptions.js \
	main.js \
	section.js \
	settings.js \
	podkop-dns-optimizer \
	podkop-subscription-maintenance-upgrade.sh \
	podkop-subscription-urltest-runtime.patch \
	podkop-subscription-v0719-runtime.patch \
	podkop-subscription-cache-only-upgrade.patch \
	podkop-subscription-actions-upgrade.patch \
	podkop-subscription-legacy-upgrade.patch \
	podkop-actions-ui-fix.sh \
	runtime-0.7.20/usr/bin/podkop \
	runtime-0.7.20/www/luci-static/resources/view/podkop/podkop.js
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
