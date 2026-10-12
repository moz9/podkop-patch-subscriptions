#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' "$root/openwrt/install.sh" > "$work/installer"
. "$work/installer"
command -v ensure_native_dns_runtime_hooks >/dev/null || { echo 'FAIL: installed runtime lacks DNS hook upgrade'; exit 1; }
abort_with_restore() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$work/lib"
printf 'native_marker=base\n' > "$work/lib/sing_box_config_facade.sh"
printf 'native_marker=native\n' > "$work/lib/dns-native.sh"
printf '%s\n' '#!/bin/sh' '. "$PODKOP_LIB/sing_box_config_facade.sh"' 'unrelated_function() { echo preserved; }' 'case "$1" in' '*) echo DISPATCHED;;' 'esac' > "$work/target"
chmod 755 "$work/target"
ensure_native_dns_runtime_hooks "$work/target"
grep -Fq '[ ! -r "$PODKOP_LIB/dns-native.sh" ] || . "$PODKOP_LIB/dns-native.sh"' "$work/target"
grep -Fq '[ "${PODKOP_LIBRARY_ONLY:-0}" != 1 ] || return 0' "$work/target"
grep -Fq 'unrelated_function() { echo preserved; }' "$work/target"
PODKOP_LIB="$work/lib" PODKOP_LIBRARY_ONLY=1 . "$work/target"
[ "$native_marker" = native ]
cp "$work/target" "$work/once"
ensure_native_dns_runtime_hooks "$work/target"
cmp "$work/once" "$work/target"
grep -Fq "! grep -q 'ACTIVE_BOOTSTRAP_DNS_TYPE' /usr/bin/podkop" "$root/openwrt/install.sh"
cmp "$root/i" "$root/openwrt/install.sh"
echo 'PASS: old installed legacy runtime receives native source/library guard and typed bootstrap upgrade'
