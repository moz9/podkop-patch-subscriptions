#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo/i" > "$tmp/library"
. "$tmp/library"
command -v capture_live_patch_runtime >/dev/null || fail 'patch installer cannot preserve a healthy live runtime'
query_service_running_state() { echo running; }
has_subscription_backend() { return 0; }
PODKOP_PATCH_UPDATE_PODKOP=0
fingerprint=original
patch_runtime_fingerprint() { echo "$fingerprint"; }
capture_live_patch_runtime
[ "$live_patch_runtime" = original ] || fail 'healthy runtime was not captured'
verify_live_patch_runtime || fail 'unchanged runtime rejected'
# Run the real activation block with strict traps for every traffic-changing
# command, not just an assertion on the helper implementation.
sed -n '/^if command -v sing-box .*config.json.*then$/,/^\/etc\/init.d\/rpcd restart/p' "$repo/i" | sed '$d' > "$tmp/activate"
[ -s "$tmp/activate" ] || fail 'activation fixture is empty'
run_podkop_reload_with_retry() { fail 'file-only update restarted the proxy'; }
mkdir "$tmp/bin"
printf '#!/bin/sh\n[ "$1" = check ]\n' > "$tmp/bin/sing-box"
chmod 755 "$tmp/bin/sing-box"
PATH="$tmp/bin:$PATH"
abort_with_restore() { fail "$*"; }
. "$tmp/activate"
[ "${runtime_activation_started:-0}" = 0 ] || fail 'file-only update entered service activation'
fingerprint=changed
verify_live_patch_runtime && fail 'changed active graph or process accepted' || :
fingerprint=original
restart_podkop_after_restore() { fail 'file-only rollback restarted Podkop and refreshed subscriptions'; }
DNS_FAILOVER_INIT_SCRIPT="$tmp/absent"
dns_failover_service_state=absent
restore_patch_service_state || fail 'file-only service restore failed'
PODKOP_PATCH_UPDATE_PODKOP=1
capture_live_patch_runtime
[ -z "$live_patch_runtime" ] || fail 'full-stack upgrade was treated as file-only'
grep -q 'verify_live_patch_runtime || abort_with_restore' "$repo/i" || fail 'installer does not verify file-only activation'
grep -q "! grep -Fqx 'subscription_services_snapshot_unfiltered() {' /usr/bin/podkop" "$repo/i" || fail 'existing installs would skip the lifecycle hotfix'
echo 'PASS: healthy patch-only update and rollback preserve the exact live runtime'
