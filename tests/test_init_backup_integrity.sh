#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
for name in init_file_hash backup_init_generation backup_init_once; do
    sed -n "/^$name() {$/,/^}$/p" "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >> "$work/library"
done
. "$work/library"
fail() { echo "FAIL: $*" >&2; exit 1; }
echo '# original' > "$work/init"
chmod 751 "$work/init"
sum="$(md5sum "$work/init" | cut -d' ' -f1)"
backup_init_generation "$work/init"
cmp "$work/init" "$work/init.gen-$sum" || fail 'wrong generation'
echo corrupt > "$work/init.gen-$sum"
! backup_init_generation "$work/init" || fail 'corrupt generation trusted'
[ "$(cat "$work/init.gen-$sum")" = corrupt ] || fail 'bad backup silently overwritten'
rm "$work/init.gen-$sum"
ln -s "$work/init" "$work/init.gen-$sum"
! backup_init_generation "$work/init" || fail 'symlink generation trusted'
rm "$work/init.gen-$sum"
backup_init_once "$work/init" "$work/first"
echo '# later' > "$work/init"
backup_init_once "$work/init" "$work/first"
[ "$(cat "$work/first")" = '# original' ] || fail 'oldest backup replaced'
md5sum() { return 1; }
! backup_init_generation "$work/init" || fail 'unverifiable backup accepted'
md5sum() { echo '../unsafe not-a-hash'; }
! backup_init_generation "$work/init" || fail 'malformed checksum accepted'
echo 'PASS: recoverable generations reject corruption, links and broken hashes; first backup is immutable'
