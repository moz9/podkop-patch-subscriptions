#!/bin/sh
set -eu

target="${PODKOP_SUBSCRIPTION_APPLY_V2_TARGET:-/usr/bin/podkop}"
source_runtime="${PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE:-}"
patch_version="${PODKOP_PATCH_VERSION:-main}"
raw_base="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$patch_version/openwrt}"
tmp_dir="$(mktemp -d /tmp/podkop-subscription-apply-v2-upgrade.XXXXXX)"
staged_target="${target}.subscription-apply-v2.$$"

cleanup() {
    rm -rf "$tmp_dir"
    rm -f "$staged_target"
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'Subscription apply v2 upgrade failed: %s\n' "$1" >&2
    exit 1
}

download_source_runtime() {
    local url="$raw_base/runtime-0.7.20/usr/bin/podkop"
    local output="$tmp_dir/source-runtime"

    if command -v curl > /dev/null 2>&1 &&
        curl -fsSL --connect-timeout 10 -m 45 -o "$output" "$url"; then
        source_runtime="$output"
        return 0
    fi
    if command -v wget > /dev/null 2>&1 &&
        wget --no-check-certificate -T 45 -O "$output" "$url"; then
        source_runtime="$output"
        return 0
    fi
    return 1
}

[ -f "$target" ] || fail "runtime not found at $target"
grep -q '^set_subscription_links_enabled() {' "$target" ||
    fail 'subscription selection backend is not installed'

version="$($target show_version 2> /dev/null | sed 's/^v//' | head -n 1 || true)"
case "$version" in
0.7.19 | 0.7.20 | 0.7.21 | 0.7.22) ;;
*) fail "unsupported Podkop version: ${version:-unknown}" ;;
esac

if grep -Fqx '# subscription_apply_v2 begin' "$target" &&
    grep -Fqx '# subscription_apply_v2 end' "$target" &&
    grep -q '^set_subscription_sections_enabled)' "$target" &&
    grep -q '^subscription_action_lock_dir() {' "$target"; then
    printf '%s\n' 'Subscription apply v2 is already installed.'
    exit 0
fi

if [ -z "$source_runtime" ]; then
    download_source_runtime || fail 'unable to download canonical v2 runtime source'
fi
[ -f "$source_runtime" ] || fail "canonical runtime source not found at $source_runtime"

grep -Fqx '# subscription_apply_v2 begin' "$source_runtime" || fail 'canonical v2 block start marker is missing'
grep -Fqx '# subscription_apply_v2 end' "$source_runtime" || fail 'canonical v2 block end marker is missing'
grep -q '^subscription_action_lock_dir() {' "$source_runtime" || fail 'canonical atomic lock is missing'
sh -n "$source_runtime" || fail 'canonical runtime source has invalid shell syntax'

sed -n '/^# subscription_apply_v2 begin$/,/^# subscription_apply_v2 end$/p' "$source_runtime" > "$tmp_dir/v2.block"
sed -n '/^subscription_action_lock_file() {$/,/^# sing-box funcs$/p' "$source_runtime" |
    sed '$d' > "$tmp_dir/lock.block"
[ -s "$tmp_dir/v2.block" ] || fail 'canonical v2 block is empty'
[ -s "$tmp_dir/lock.block" ] || fail 'canonical lock block is empty'

awk -v block="$tmp_dir/lock.block" '
BEGIN { replacing = 0; replaced = 0 }
$0 == "subscription_action_lock_file() {" {
    while ((getline line < block) > 0) print line
    close(block)
    replacing = 1
    replaced = 1
    next
}
replacing && $0 == "# sing-box funcs" {
    replacing = 0
    print
    next
}
replacing { next }
{ print }
END { if (!replaced) exit 42 }
' "$target" > "$tmp_dir/runtime.lock" || fail 'unable to replace subscription action lock'

if grep -Fqx '# subscription_apply_v2 begin' "$tmp_dir/runtime.lock"; then
    awk '
    $0 == "# subscription_apply_v2 begin" { skipping = 1; next }
    skipping && $0 == "# subscription_apply_v2 end" { skipping = 0; next }
    skipping { next }
    { print }
    ' "$tmp_dir/runtime.lock" > "$tmp_dir/runtime.clean"
else
    cp "$tmp_dir/runtime.lock" "$tmp_dir/runtime.clean"
fi

awk -v block="$tmp_dir/v2.block" '
BEGIN { inserted = 0 }
!inserted && $0 == "subscription_update_section_handler() {" {
    while ((getline line < block) > 0) print line
    close(block)
    print ""
    inserted = 1
}
{ print }
END { if (!inserted) exit 42 }
' "$tmp_dir/runtime.clean" > "$tmp_dir/runtime.v2" || fail 'unable to insert v2 transaction backend'

awk '
BEGIN { help_inserted = 0; case_inserted = 0 }
$0 == "    set_subscription_sections_enabled" || $0 == "set_subscription_sections_enabled)" {
    skip_existing = 1
}
skip_existing && $0 == "                            Transactionally apply JSON changes for multiple sections" {
    skip_existing = 0
    next
}
skip_existing && $0 == "    set_subscription_sections_enabled \"$2\"" { next }
skip_existing && $0 == "    ;;" { skip_existing = 0; next }
skip_existing { next }

!help_inserted && $0 == "    set_subscription_links_enabled" {
    print "    set_subscription_sections_enabled"
    print "                            Transactionally apply JSON changes for multiple sections"
    help_inserted = 1
}
!case_inserted && $0 == "set_subscription_links_enabled)" {
    print "set_subscription_sections_enabled)"
    print "    set_subscription_sections_enabled \"$2\""
    print "    ;;"
    case_inserted = 1
}
{ print }
END { if (!help_inserted || !case_inserted) exit 42 }
' "$tmp_dir/runtime.v2" > "$tmp_dir/runtime.final" || fail 'unable to install v2 help or dispatcher entries'

grep -Fqx '# subscription_apply_v2 begin' "$tmp_dir/runtime.final" || fail 'v2 block verification failed'
grep -q '^set_subscription_sections_enabled)' "$tmp_dir/runtime.final" || fail 'dispatcher verification failed'
grep -q '^subscription_action_lock_dir() {' "$tmp_dir/runtime.final" || fail 'atomic lock verification failed'
sh -n "$tmp_dir/runtime.final" || fail 'upgraded runtime has invalid shell syntax'

backup="${PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP:-/root/podkop-subscription-apply-v2-backup-$(date +%Y%m%d-%H%M%S)-$$}"
cp -p "$target" "$backup" || fail 'unable to back up current runtime'
cp "$tmp_dir/runtime.final" "$staged_target" || fail 'unable to stage upgraded runtime'
chmod 755 "$staged_target" || fail 'unable to set runtime permissions'
mv "$staged_target" "$target" || fail 'unable to atomically install upgraded runtime'

printf 'Installed subscription apply v2. Backup: %s\n' "$backup"
