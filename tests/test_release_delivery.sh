#!/bin/sh
# Offline-only: extracted functions, fake transport/installer; no router commands.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
export PODKOP_PATCH_MANAGER_STATE_DIR="$work/state"
sed '/^case "$1" in/,$d' "$repo/openwrt/podkop-update-manager" > "$work/functions"
. "$work/functions"
fail_test() { echo "FAIL: $*" >&2; exit 1; }
commit=1111111111111111111111111111111111111111
real_download=$(sed -n '/^download_file() {/,/^}/p' "$work/functions")
download_file() {
 printf '%s\n' "$1" >> "$work/requests"
 case "${transport:-ok}" in fail) return 1 ;; malformed) printf '{"sha":"main"}' > "$2" ;; *) printf '{"sha":"%s"}' "$commit" > "$2" ;; esac
}
pin_release_root https://raw.githubusercontent.com/owner/repo/main "$work/ref"
[ "$PINNED_ROOT" = "https://raw.githubusercontent.com/owner/repo/$commit" ] || fail_test pin
[ "$(cat "$work/requests")" = https://api.github.com/repos/owner/repo/commits/main ] || fail_test request
: > "$work/requests"
pin_release_root "https://raw.githubusercontent.com/owner/repo/$commit" "$work/ref"
[ ! -s "$work/requests" ] || fail_test immutable-network
transport=fail
if pin_release_root https://raw.githubusercontent.com/owner/repo/main "$work/ref"; then fail_test fail-open; fi
transport=malformed
if pin_release_root https://raw.githubusercontent.com/owner/repo/main "$work/ref"; then fail_test bad-commit; fi
if pin_release_root https://mirror.example/release "$work/ref"; then fail_test unpinned-mirror; fi
PODKOP_PATCH_MANIFEST_SHA256=$(printf x | sha256sum | awk '{print $1}')
pin_release_root https://mirror.example/release "$work/ref"
unset PODKOP_PATCH_MANIFEST_SHA256
pin_release_root "file://$work/release" "$work/ref"
# Installer download must pass the approved manifest checksum before execution.
log_line() { :; }
write_status() { printf '%s %s\n' "$1" "$2" > "$work/status"; }
perform_check() {
 PINNED_ROOT="file://$work/release"
 printf '{"updateMode":"patch","canUpdate":true,"currentPodkopVersion":"0.7.24","latestPatchVersion":"test-v1"}' > "$DETAILS_FILE"
}
printf '#!/bin/sh\nexit 0\n' > "$work/installer"
hash=$(sha256sum "$work/installer" | awk '{print $1}')
printf '{"sha256":{"i":"%s"}}' "$hash" > "$STATE_DIR/manifest.json"
download_file() { [ "${transport:-ok}" != fail ] || return 1; cp "$work/installer" "$2"; }
run_with_timeout() { printf '%s\n' "$@" > "$work/executed"; }
current_podkop_version() { echo 0.7.24; }
current_patch_version() { echo test-v1; }
transport=ok
perform_update
[ -s "$work/executed" ] || fail_test not-executed
grep -Fq "PODKOP_PATCH_RAW_BASE=file://$work/release/openwrt" "$work/executed" || fail_test lost-pin
rm "$work/executed"
printf '# tampered\n' >> "$work/installer"
if perform_update; then fail_test accepted-tampered-installer; fi
[ ! -e "$work/executed" ] || fail_test executed-tamper
transport=fail
if perform_update; then fail_test accepted-download-failure; fi
[ ! -e "$work/executed" ] || fail_test executed-after-failure
# A contender must not clear an owner's directory, log or status.
mkdir "$LOCK_DIR"
printf 'other-owner\n' > "$LOCK_DIR/token"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf sentinel > "$LOG_FILE"
if start_worker check > "$work/result"; then fail_test concurrent-start; fi
[ "$(cat "$LOCK_DIR/token")" = other-owner ] || fail_test lock-removed
[ "$(cat "$LOG_FILE")" = sentinel ] || fail_test log-truncated
WORKER_TOKEN=wrong-owner
release_worker_lock
[ -d "$LOCK_DIR" ] || fail_test wrong-owner-release
# Transport and helpers must never disable certificate verification.
for file in i s openwrt/podkop-update-manager openwrt/podkop-subscription-maintenance-upgrade.sh openwrt/podkop-subscription-apply-v2-upgrade.sh openwrt/podkop-subscription-seamless-reload-upgrade.sh; do
 if grep -q -- '--no-check-certificate' "$repo/$file"; then fail_test "insecure TLS in $file"; fi
done
printf sentinel > "$work/outside"
ln -s "$work/outside" "$work/untrusted-output"
if prepare_owned_file "$work/untrusted-output"; then fail_test symlink-output; fi
[ "$(cat "$work/outside")" = sentinel ] || fail_test output-followed
mkdir "$work/untrusted-dir"
chmod 777 "$work/untrusted-dir"
if owned_nonwritable_path "$work/untrusted-dir"; then fail_test writable-state; fi
ln -s "$work/state" "$work/state-link"
if PODKOP_PATCH_MANAGER_STATE_DIR="$work/state-link" sh "$repo/openwrt/podkop-update-manager" version > "$work/rejected-state" 2>&1; then fail_test symlink-state; fi
grep -q untrusted_state_directory "$work/rejected-state" || fail_test wrong-state-error
echo 'PASS: immutable resolution, pinned mirror contract, installer tampering/download refusal, owner-only locks and verified TLS'
