#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
guard="$repo/openwrt/podkop-memdoc-guard"
upgrade="$repo/openwrt/podkop-memdoc-upgrade.sh"
[ -f "$guard" ] || fail 'memdoc ownership guard is missing'
[ -f "$upgrade" ] || fail 'memdoc compatibility upgrader is missing'
export PODKOP_MEMDOC_ROOT="$work/root" PODKOP_MEMDOC_SECTION_LOCK="$work/section.lock"
export PODKOP_MEMDOC_TARGET="$work/memdoc" PODKOP_MEMDOC_SHELL=sh
mkdir -p "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime" "$PODKOP_MEMDOC_ROOT/usr/bin" "$PODKOP_MEMDOC_ROOT/tmp" "$PODKOP_MEMDOC_ROOT/proc/101" "$work/bin"
printf '#!/bin/sh\nprintf "101\\n"\n' > "$work/bin/pidof"
chmod +x "$work/bin/pidof"
PATH="$work/bin:$PATH"; export PATH
allow() { sh "$guard" "$1" || fail "unexpectedly blocked: $1"; }
block() { if sh "$guard" "$1"; then fail "unexpectedly allowed: $1"; fi; }
allow /etc/init.d/sing-box
printf '#!/bin/sh\n' > "$PODKOP_MEMDOC_ROOT/usr/bin/podkop"
printf '#!/bin/sh\n' > "$PODKOP_MEMDOC_ROOT/usr/bin/podkop-section-runtime"
chmod +x "$PODKOP_MEMDOC_ROOT/usr/bin/podkop" "$PODKOP_MEMDOC_ROOT/usr/bin/podkop-section-runtime"
printf 'single\n' > "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime/runtime-mode"
allow /etc/init.d/sing-box # Marker alone does not prove process ownership.
printf '/usr/bin/sing-box\000run\000-c\000/etc/other/config.json\000' > "$PODKOP_MEMDOC_ROOT/proc/101/cmdline"
allow /etc/init.d/sing-box
printf '/usr/bin/sing-box\000run\000-c\000/etc/sing-box/config.json\000' > "$PODKOP_MEMDOC_ROOT/proc/101/cmdline"
block /etc/init.d/sing-box
allow /etc/init.d/xray
allow /etc/init.d/bridger
rm "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime/runtime-mode"
printf '{"section":"main","port":19160,"api_port":19163}\n' > "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime/metadata.json"
block /etc/init.d/sing-box
printf 'unknown\n' > "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime/runtime-mode"
allow /etc/init.d/sing-box # Do not infer ownership from unknown runtime modes.
rm "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime/runtime-mode"
printf '{"section":"main","port":"19160","api_port":19163}\n' > "$PODKOP_MEMDOC_ROOT/etc/podkop/section-runtime/metadata.json"
allow /etc/init.d/sing-box
printf '%s installer 0\n' "$$" > "$PODKOP_MEMDOC_ROOT/tmp/podkop-subscription-action.lock"
block /etc/init.d/bridger
block /etc/init.d/xray
printf '99999999 installer 0\n' > "$PODKOP_MEMDOC_ROOT/tmp/podkop-subscription-action.lock"
allow /etc/init.d/bridger
rm "$PODKOP_MEMDOC_ROOT/tmp/podkop-subscription-action.lock"
mkdir "$PODKOP_MEMDOC_ROOT/tmp/podkop-subscription-action.lock.d"
block /etc/init.d/bridger # Ownerless atomic lock creation window.
rmdir "$PODKOP_MEMDOC_ROOT/tmp/podkop-subscription-action.lock.d"
printf '99999999 stale\n' > "$PODKOP_MEMDOC_SECTION_LOCK"
allow /etc/init.d/bridger # Persistent flock inode is not a held transaction.
(
    exec 9> "$PODKOP_MEMDOC_SECTION_LOCK"
    flock -n 9 || exit 1
    block /etc/init.d/bridger
)
allow /etc/init.d/bridger

# Exact live OFFICE variant, read-only collected 2026-10-12 after reboot.
# HOME has no memdoc. Preserve user changes outside the audited function.
sed 's/THRESHOLD=20000/THRESHOLD=23456/' "$repo/tests/fixtures/memdoc-office-20261012.sh" > "$PODKOP_MEMDOC_TARGET"
cp "$PODKOP_MEMDOC_TARGET" "$work/original"
sh "$upgrade"
grep -Fq '# podkop_memdoc_guard begin' "$PODKOP_MEMDOC_TARGET" || fail 'guard not inserted'
grep -Fq 'THRESHOLD=23456' "$PODKOP_MEMDOC_TARGET" || fail 'user threshold lost'
cp "$PODKOP_MEMDOC_TARGET" "$work/patched"
sh "$upgrade"
cmp -s "$PODKOP_MEMDOC_TARGET" "$work/patched" || fail 'upgrade is not idempotent'
sh "$upgrade" restore
cmp -s "$PODKOP_MEMDOC_TARGET" "$work/original" || fail 'rollback did not restore exact source'
sh "$upgrade"
printf '# later user edit\n' >> "$PODKOP_MEMDOC_TARGET"
if sh "$upgrade" restore >/dev/null 2>&1; then fail 'rollback overwrote later user edit'; fi
cp "$PODKOP_MEMDOC_TARGET" "$work/edited"
if sh "$upgrade" >/dev/null 2>&1; then fail 'idempotent install accepted changed managed script'; fi
cmp -s "$PODKOP_MEMDOC_TARGET" "$work/edited" || fail 'refusal changed source'
PODKOP_MEMDOC_TARGET="$work/absent" sh "$upgrade" # HOME absent watchdog is a no-op.
printf '#!/bin/sh\nrestart_service_if_running() {\n    killall sing-box\n}\n' > "$work/unknown"
if PODKOP_MEMDOC_TARGET="$work/unknown" sh "$upgrade" >/dev/null 2>&1; then fail 'unknown variant was patched'; fi
grep -Fq 'killall sing-box' "$work/unknown" || fail 'unknown variant changed'
echo 'PASS: memdoc managed ownership, active/stale transactions, unrelated services, exact/idempotent upgrade and guarded rollback'
