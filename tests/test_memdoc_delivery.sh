#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for asset in podkop-single-runtime podkop-memdoc-guard podkop-memdoc-upgrade.sh; do
    grep -Fq "$asset" "$repo/i" || fail "installer missing $asset"
    grep -Fq "$asset" "$repo/s" || fail "safe updater missing $asset"
done
cmp -s "$repo/i" "$repo/openwrt/install.sh" || fail 'installer mirrors differ'
for path in usr/bin/podkop-single-runtime usr/libexec/podkop-memdoc-guard usr/bin/memdoc usr/bin/memdoc.podkop-original usr/bin/memdoc.podkop-guarded; do
    sed -n '/^RUNTIME_FILES="/,/^"/p' "$repo/i" | grep -Fqx "$path" || fail "runtime rollback does not cover $path"
done
sed -n '/^install_memdoc_compatibility() {/,/^}/p' "$repo/i" > "$work/function.sh"
[ -s "$work/function.sh" ] || fail 'watchdog compatibility installer hook missing'
. "$work/function.sh"
tmp_dir="$repo/openwrt"
MEMDOC_GUARD_FILE=podkop-memdoc-guard MEMDOC_UPGRADE_FILE=podkop-memdoc-upgrade.sh
export SECTION_INSTALL_ROOT="$work/root" PODKOP_MEMDOC_SHELL=sh
mkdir -p "$SECTION_INSTALL_ROOT/usr/bin" "$SECTION_INSTALL_ROOT/etc/init.d"
install_memdoc_compatibility || fail 'absent memdoc should be a no-op'
cp "$repo/tests/fixtures/memdoc-office-20261012.sh" "$SECTION_INSTALL_ROOT/usr/bin/memdoc"
cat > "$SECTION_INSTALL_ROOT/etc/init.d/memdoc" <<'INIT'
#!/bin/sh
case "$1" in
    status) [ -f "$SECTION_INSTALL_ROOT/was-running" ] && echo running || echo stopped;;
    restart) echo restart >> "$SECTION_INSTALL_ROOT/restarts";;
    *) exit 99;;
esac
INIT
chmod +x "$SECTION_INSTALL_ROOT/etc/init.d/memdoc"
install_memdoc_compatibility || fail 'stopped watchdog install failed'
[ ! -e "$SECTION_INSTALL_ROOT/restarts" ] || fail 'installer started a stopped watchdog'
touch "$SECTION_INSTALL_ROOT/was-running"
install_memdoc_compatibility || fail 'running watchdog installation failed'
[ "$(cat "$SECTION_INSTALL_ROOT/restarts")" = restart ] || fail 'running watchdog not restarted exactly once'
grep -Fq '# podkop_memdoc_guard begin' "$SECTION_INSTALL_ROOT/usr/bin/memdoc" || fail 'watchdog not patched'
echo 'PASS: single helper/watchdog delivery, rollback inventory, absent/stopped/running memdoc policy'
