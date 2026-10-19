#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo/i" > "$work/library"
. "$work/library"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v installer_services_deferred >/dev/null || fail_test 'migration service deferral is missing'
PODKOP_PATCH_DEFER_SERVICE_START=0
if installer_services_deferred; then fail_test 'normal installation skips activation'; fi
PODKOP_PATCH_DEFER_SERVICE_START=1
installer_services_deferred || fail_test 'migration flag not honored'
restore_calls=0
restart_podkop_after_restore() { restore_calls=$((restore_calls + 1)); }
restore_patch_service_state || fail_test 'deferred rollback failed'
[ "$restore_calls" = 0 ] || fail_test 'child rollback started incompatible service'
sed -n '/^# ACTIVATE_INSTALLED_PATCH$/,/^transaction_phase="committed"$/p' "$repo/i" > "$work/activation"
grep -q 'installer_services_deferred' "$work/activation" || fail_test 'final activation ignores migration flag'
mkdir "$work/init"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/activation.calls"\n' "$work" > "$work/init/podkop-dns-failover"
cp "$work/init/podkop-dns-failover" "$work/init/podkop"
chmod +x "$work/init/"*
sed "s|/etc/init.d/|$work/init/|g" "$work/activation" > "$work/activation-safe"
abort_with_restore() { fail_test "$*"; }
reload_calls=0
run_podkop_reload_with_retry() { reload_calls=$((reload_calls + 1)); }
light_reload=0
PODKOP_PATCH_DEFER_SERVICE_START=1
. "$work/activation-safe"
[ "$reload_calls" = 0 ] && [ ! -e "$work/activation.calls" ] || fail_test 'deferred final path activated services'
PODKOP_PATCH_DEFER_SERVICE_START=0
. "$work/activation-safe"
[ "$reload_calls" = 1 ] || fail_test 'normal final path did not reload Podkop'
[ "$(wc -l < "$work/activation.calls")" = 2 ] || fail_test 'normal final path did not enable and restart DNS failover'
printf 'PASS: migration child defers activation and service restore\n'
