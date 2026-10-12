#!/bin/sh
set -eu

PATCH_VERSION="${PODKOP_PATCH_VERSION:-main}"
RAW_ROOT="${PODKOP_PATCH_RAW_ROOT:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PATCH_VERSION}"
RAW_BASE="$RAW_ROOT/openwrt"
WORK_ROOT="${PODKOP_PATCH_SAFE_WORK_DIR:-/tmp/podkop-patch-safe-update}"
WORK_DIR=""
LOG_FILE="${PODKOP_PATCH_SAFE_LOG:-/tmp/podkop-patch-safe-update.log}"
STATUS_FILE="${PODKOP_PATCH_SAFE_STATUS:-/tmp/podkop-patch-safe-update.status}"
LOCK_DIR="$WORK_ROOT.lock"
LOCK_TOKEN="$$:$(date +%s)"
LOCK_OWNED=0
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
		file://*|/*)
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

# Resolve a mutable GitHub ref once. All release bytes use the returned commit.
# Local releases are an explicit caller-owned trust boundary.
pin_release_root() {
    local source="$1" metadata="$2" tail owner repository ref encoded commit
    case "$source" in
    file:///*|/*) PINNED_ROOT="${source%/}"; return 0 ;;
    https://raw.githubusercontent.com/*) ;;
    https://*)
        # A caller-pinned manifest authenticates an explicit HTTPS mirror.
        printf '%s\n' "${PODKOP_PATCH_MANIFEST_SHA256:-}" | grep -Eq '^[0-9a-f]{64}$' || return 1
        PINNED_ROOT="${source%/}"; return 0 ;;
    *) return 1 ;;
    esac
    tail="${source#https://raw.githubusercontent.com/}"
    owner="${tail%%/*}"; tail="${tail#*/}"
    repository="${tail%%/*}"; ref="${tail#*/}"
    case "$owner/$repository" in *[!a-zA-Z0-9_./-]*|'/' ) return 1 ;; esac
    [ -n "$owner" ] && [ -n "$repository" ] && [ -n "$ref" ] || return 1
    if printf '%s\n' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
        commit="$ref"
    else
        encoded="$(printf '%s' "$ref" | jq -sRr @uri)" || return 1
        download "https://api.github.com/repos/$owner/$repository/commits/$encoded" "$metadata" || return 1
        commit="$(jq -er '.sha | select(type == "string" and length == 40)' "$metadata")" || return 1
    fi
    printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{40}$' || return 1
    PINNED_ROOT="https://raw.githubusercontent.com/$owner/$repository/$commit"
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

owned_nonwritable_path() {
    local info owner permissions
    [ ! -L "$1" ] || return 1
    info="$(LC_ALL=C ls -nd "$1" 2>/dev/null)" || return 1
    owner="$(printf '%s\n' "$info" | awk '{print $3}')"
    permissions="$(printf '%s\n' "$info" | awk '{print $1}')"
    [ "$owner" = "$(id -u)" ] || return 1
    case "$permissions" in ?????w*|????????w*) return 1 ;; esac
}

prepare_owned_file() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        (umask 077; set -C; : > "$1") 2>/dev/null || return 1
    fi
    [ -f "$1" ] && owned_nonwritable_path "$1"
}

release_stage_lock() {
    [ "$LOCK_OWNED" = 1 ] || return 0
    [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$LOCK_TOKEN" ] || return 0
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
# Never reclaim a possibly live or interrupted transaction automatically.
# Recovery/operator inspection is required for an orphaned lock.
umask 077
mkdir -p "$(dirname "$WORK_ROOT")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' 'ERROR: safe updater is busy; existing staging lock retained' >&2
    exit 1
fi
LOCK_OWNED=1
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_DIR/owner"
for output_path in "$LOG_FILE" "$STATUS_FILE" "$PID_FILE"; do
    if ! prepare_owned_file "$output_path"; then
        printf '%s\n' 'ERROR: updater output is not an owned, non-writable regular file' >&2
        release_stage_lock
        exit 1
    fi
done
trap 'release_stage_lock' EXIT
stage_interrupted() {
    printf 'failed %s reason=interrupted\n' "$(date +%s)" > "$STATUS_FILE" 2>/dev/null || true
    exit "$1"
}
trap 'stage_interrupted 130' INT
trap 'stage_interrupted 143' TERM
trap 'stage_interrupted 129' HUP
umask 077
# Never reuse a caller-provided or predictable directory tree as root output.
WORK_DIR="$(mktemp -d "$WORK_ROOT.XXXXXX")" || fail "cannot allocate private release staging"
ASSET_DIR="$WORK_DIR/openwrt"
INSTALLER="$WORK_DIR/i"
RUNNER="$WORK_DIR/run.sh"
mkdir -p "$ASSET_DIR"
: > "$LOG_FILE"
printf 'prefetch %s\n' "$(date +%s 2>/dev/null || date)" > "$STATUS_FILE"

command -v jq >/dev/null 2>&1 || fail "jq utility is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum utility is required"
pin_release_root "$RAW_ROOT" "$WORK_DIR/release-commit.json" || fail "cannot pin patch release to an immutable commit"
RAW_ROOT="$PINNED_ROOT"
RAW_BASE="$RAW_ROOT/openwrt"
MANIFEST="$ASSET_DIR/update-manifest.json"
download "$RAW_BASE/update-manifest.json?t=$(date +%s)" "$MANIFEST"
if [ -n "${PODKOP_PATCH_MANIFEST_SHA256:-}" ]; then
    [ "$(sha256sum "$MANIFEST" | awk '{print $1}')" = "$PODKOP_PATCH_MANIFEST_SHA256" ] || fail "release manifest changed after approval"
fi
jq -e '.schemaVersion == 1 and (.channel // "legacy") == "legacy" and (.patchVersion | type == "string") and (.sha256 | type == "object")' "$MANIFEST" >/dev/null ||
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
	podkop-dns-apply \
	podkop-dns-native.sh \
	dns_benchmark.js \
	dns-main.json \
	dns-bootstrap.json \
	podkop-dns-failover \
	podkop-dns-failover.init \
	podkop-dns-failover-upgrade.sh \
	podkop-subscription-apply-v2-upgrade.sh \
	podkop-subscription-sources-upgrade.sh \
	podkop-subscription-seamless-reload-upgrade.sh \
	podkop-section-runtime \
	podkop-single-runtime \
	podkop-memdoc-guard \
	podkop-memdoc-upgrade.sh \
	podkop-section-worker.init \
	podkop-section-hooks.sh \
	podkop-section-upgrade.sh \
	podkop-section-runtime-upgrade.patch \
	podkop-update-manager \
	podkop-actions-ui-fix.sh \
	podkop-subscription-actions-upgrade.patch \
	podkop-subscription-legacy-upgrade.patch \
	podkop-subscription-v0719-runtime.patch \
	podkop-subscription-maintenance-upgrade.sh \
	podkop-update-center-upgrade.sh \
	runtime-0.7.20/usr/bin/podkop \
	runtime-0.7.20/www/luci-static/resources/view/podkop/podkop.js \
	runtime-0.7.22/usr/bin/podkop \
	runtime-0.7.22/www/luci-static/resources/view/podkop/podkop.js
do
	fetch_asset "$rel"
done

cat > "$RUNNER" <<EOF
#!/bin/sh
set +e
trap 'if [ "\$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$LOCK_TOKEN" ]; then rm -rf "$WORK_DIR"; rm -f "$LOCK_DIR/owner"; rmdir "$LOCK_DIR" 2>/dev/null || true; fi' EXIT
stop_installer() {
    local child descendant
    child="\$1"
    if [ -r "/proc/\$child/task/\$child/children" ]; then
    for descendant in \$(cat "/proc/\$child/task/\$child/children"); do
        stop_installer "\$descendant"
    done
    fi
    kill -TERM "\$child" 2>/dev/null || true
}
interrupted() {
    trap '' INT TERM HUP
    [ -z "\${installer_pid:-}" ] || { stop_installer "\$installer_pid"; wait "\$installer_pid" 2>/dev/null; }
    printf 'failed %s reason=interrupted\\n' "\$(date +%s)" > "$STATUS_FILE"
    exit "\$1"
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap 'interrupted 129' HUP
exec >> "$LOG_FILE" 2>&1
printf 'running %s\\n' "\$(date +%s 2>/dev/null || date)" > "$STATUS_FILE"
PODKOP_PATCH_RAW_BASE="file://$ASSET_DIR" sh "$INSTALLER" &
installer_pid=\$!
wait "\$installer_pid"
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
	exec sh "$RUNNER"
fi

LOCK_OWNED=0
if command -v nohup >/dev/null 2>&1; then
	nohup sh "$RUNNER" >/dev/null 2>&1 </dev/null &
else
	sh "$RUNNER" >/dev/null 2>&1 </dev/null &
fi
echo "$!" > "$PID_FILE"
LOCK_OWNED=0
printf 'started pid=%s\n' "$(cat "$PID_FILE")"
printf 'log=%s\n' "$LOG_FILE"
printf 'status=%s\n' "$STATUS_FILE"
