#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
for version in 0.7.20 0.7.22 0.7.23; do
    runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
    grep -Fq '[ "${PODKOP_LIBRARY_ONLY:-0}" != 1 ] || return 0' "$runtime" || fail "core $version lacks library-only guard"
    awk '/PODKOP_LIBRARY_ONLY/ { guard=NR } /^case "\$1" in/ { if (!guard || guard>=NR) exit 1; found=1 } END { if (!found) exit 1 }' "$runtime" || fail "core guard must precede dispatcher"
done
for installer in i openwrt/install.sh; do
    grep -Fq 'DNS_APPLY_FILE="podkop-dns-apply"' "$repo/$installer" || fail 'missing DNS apply asset'
    grep -Fq 'download "$RAW_BASE/$DNS_APPLY_FILE" "$tmp_dir/$DNS_APPLY_FILE"' "$repo/$installer" || fail 'missing verified helper download'
    grep -Fq 'cp "$tmp_dir/$DNS_APPLY_FILE" /usr/bin/podkop-dns-apply' "$repo/$installer" || fail 'missing helper installation'
    grep -Fxq 'usr/bin/podkop-dns-apply' "$repo/$installer" || fail 'missing helper backup/restore'
done
cmp "$repo/i" "$repo/openwrt/install.sh" || fail 'installer copies differ'
grep -Fq 'podkop-dns-apply \' "$repo/s" || fail 'offline asset set lacks helper'
echo 'DNS transaction delivery contract: PASS'
