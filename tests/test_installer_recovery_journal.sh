#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Source functions only. Even unconditional UI cache/service cleanup is mapped
# into this fixture; no system init, package manager, network, or router runs.
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' \
    -e "s|/tmp/luci-|$test_root/luci-|g" \
    -e "s|/etc/init.d/rpcd|$test_root/absent-rpcd|g" \
    -e "s|/etc/init.d/uhttpd|$test_root/absent-uhttpd|g" \
    -e "s|/etc/init.d/memdoc|$test_root/absent-memdoc|g" \
    "$repo_root/i" > "$test_root/library"
cat > "$test_root/fixture" <<'FIXTURE'
. "$LIBRARY"
BACKUP_ROOT="$CASE_ROOT/backups"
tmp_dir="$CASE_ROOT/stage"
RUNTIME_FILES="${CASE_ROOT#/}/runtime ${CASE_ROOT#/}/dangling"
PERSISTENT_PATHS="${CASE_ROOT#/}/persistent"
DNS_FAILOVER_INIT_SCRIPT="$CASE_ROOT/absent-failover"
backup_dir=""
rollback_dir=""
backup_complete=0
restore_on_fail=0
restore_done=0
transaction_phase=prepatch
podkop_package_generation() { cat "$CASE_ROOT/generation"; }
capture_patch_service_state() { dns_failover_service_state=stopped; }
restore_patch_service_state() {
    printf '%s\n' "$dns_failover_service_state" >> "$CASE_ROOT/restores"
    printf '%s\n' "${PODKOP_PATCH_DEFER_SERVICE_START:-0}" > "$CASE_ROOT/restored-defer"
    [ ! -e "$CASE_ROOT/fail-restart" ]
}
df() {
    case "${SPACE_MODE:-ok}" in
        unreadable) return 1 ;;
        low) available=1 ;;
        staging) case "$3" in "$tmp_dir") available=1 ;; *) available=9999999 ;; esac ;;
        destination) case "$3" in "$CASE_ROOT/runtime") available=1 ;; *) available=9999999 ;; esac ;;
        *) available=9999999 ;;
    esac
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 9999999 1 %s 1%% /\n' "$available"
    [ "${SPACE_MODE:-ok}" != partial-error ]
}
cp() {
    command cp "$@" || return
    if [ "${INTERRUPT_RESTORE:-0}" = 1 ]; then kill -KILL "$$"; fi
}
sync() { [ "${FAIL_SYNC:-0}" != 1 ]; }
FIXTURE
LIBRARY="$test_root/library" FIXTURE="$test_root/fixture"
export LIBRARY FIXTURE

new_case() {
    CASE_ROOT="$test_root/$1"
    export CASE_ROOT
    mkdir -p "$CASE_ROOT/backups" "$CASE_ROOT/stage" "$CASE_ROOT/persistent"
    printf 'old-runtime\n' > "$CASE_ROOT/runtime"
    printf 'old-config\n' > "$CASE_ROOT/persistent/config"
    ln -s missing "$CASE_ROOT/dangling"
    ln -s 'target with spaces' "$CASE_ROOT/persistent/link with spaces"
    printf 'test-package-generation\n' > "$CASE_ROOT/generation"
    printf 'staged-assets\n' > "$CASE_ROOT/stage/assets"
}

new_case real-space
sh -c '. "$FIXTURE"; unset -f df; preflight_patch_space' > "$CASE_ROOT/output" 2>&1 || fail_test 'real df/du preflight rejected fixture with dangling symlink'

for mode in low unreadable partial-error staging destination; do
    new_case "space-$mode"
    if SPACE_MODE="$mode" sh -c '. "$FIXTURE"; backup_runtime; printf mutated > "$CASE_ROOT/runtime"' > "$CASE_ROOT/output" 2>&1; then
        fail_test "$mode free-space result allowed patch mutation"
    fi
    [ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] || fail_test "$mode changed runtime"
    [ -z "$(find "$CASE_ROOT/backups" -mindepth 1 -print)" ] || fail_test "$mode created backup before preflight passed"
done

new_case sync-failure
if FAIL_SYNC=1 sh -c '. "$FIXTURE"; backup_runtime; printf mutated > "$CASE_ROOT/runtime"' > "$CASE_ROOT/output" 2>&1; then
    fail_test 'failed durability barrier armed patch writes'
fi
[ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] || fail_test 'failed journal flush changed runtime'
[ -z "$(find "$CASE_ROOT/backups" -name patch-journal -print)" ] || fail_test 'failed journal flush published active state'

new_case killed-installer
if sh -c '
    . "$FIXTURE"
    backup_runtime
    printf "%s\n" "$backup_dir" > "$CASE_ROOT/selected-backup"
    printf broken-runtime > "$CASE_ROOT/runtime"
    printf broken-config > "$CASE_ROOT/persistent/config"
    rm "$CASE_ROOT/dangling"
    printf wrong-file > "$CASE_ROOT/dangling"
    kill -KILL "$$"
' > "$CASE_ROOT/killed-output" 2>&1; then
    fail_test 'SIGKILL fixture unexpectedly succeeded'
fi
selected_backup="$(cat "$CASE_ROOT/selected-backup")"
[ "$(sed -n '2p' "$selected_backup/patch-journal")" = patching ] || fail_test 'SIGKILL lost active patch journal'
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] || fail_test 'SIGKILL unexpectedly ran exit restoration'

# A changed generation must not allow even the first restore write.
printf changed-generation > "$CASE_ROOT/generation"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/generation-output" 2>&1; then fail_test 'cross-generation recovery succeeded'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] && [ ! -e "$CASE_ROOT/restores" ] || fail_test 'generation refusal mutated runtime/service'
printf 'test-package-generation\n' > "$CASE_ROOT/generation"
if sh -c '. "$FIXTURE"; RUNTIME_FILES="$RUNTIME_FILES extra/path"; recover_interrupted_patch' > "$CASE_ROOT/layout-output" 2>&1; then fail_test 'changed layout recovery succeeded'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] || fail_test 'layout refusal changed runtime'

# Journal contents are data, never shell code.
cp "$selected_backup/patch-journal" "$CASE_ROOT/saved-journal"
printf 'podkop-patch-v1\n$(touch "%s/injected")\ntest-package-generation\nstopped\n0\n0\n' "$CASE_ROOT" > "$selected_backup/patch-journal"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/malformed-output" 2>&1; then fail_test 'invalid journal accepted'; fi
[ ! -e "$CASE_ROOT/injected" ] && [ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] || fail_test 'journal executed or changed runtime'
cp "$CASE_ROOT/saved-journal" "$selected_backup/patch-journal"

# Missing and corrupted backup data must not be mistaken for originally absent
# destination paths. Refuse before stopping services or changing live files.
saved_runtime="$selected_backup/patch-rollback/${CASE_ROOT#/}/runtime"
cp "$saved_runtime" "$CASE_ROOT/saved-runtime"
rm "$saved_runtime"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/missing-snapshot-output" 2>&1; then fail_test 'missing snapshot member accepted'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] && [ ! -e "$CASE_ROOT/restores" ] || fail_test 'missing snapshot changed live state'
printf truncated > "$saved_runtime"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/corrupt-snapshot-output" 2>&1; then fail_test 'corrupt snapshot member accepted'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] || fail_test 'corrupt snapshot changed runtime'
cp "$CASE_ROOT/saved-runtime" "$saved_runtime"

# Exact symlink targets, object types, and permission modes are part of the
# typed inventory. Refuse each tampered snapshot before changing live state.
saved_link="$selected_backup/patch-rollback/${CASE_ROOT#/}/dangling"
rm "$saved_link"
ln -s changed-target "$saved_link"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/changed-link-output" 2>&1; then fail_test 'changed snapshot symlink target accepted'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] && [ ! -e "$CASE_ROOT/restores" ] || fail_test 'changed symlink target changed live state'
rm "$saved_link"
ln -s missing "$saved_link"
saved_mode="$(stat -c '%a' "$saved_runtime")"
chmod 600 "$saved_runtime"
[ "$saved_mode" != 600 ] || chmod 640 "$saved_runtime"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/changed-mode-output" 2>&1; then fail_test 'changed snapshot mode accepted'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] || fail_test 'changed mode changed live state'
chmod "$saved_mode" "$saved_runtime"
rm "$saved_link"
printf wrong-type > "$saved_link"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/changed-type-output" 2>&1; then fail_test 'changed snapshot object type accepted'; fi
[ "$(cat "$CASE_ROOT/runtime")" = broken-runtime ] || fail_test 'changed object type changed live state'
rm "$saved_link"
ln -s missing "$saved_link"

# Kill after the first restore copy, and retry from a completely new shell.
if INTERRUPT_RESTORE=1 sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/killed-restore-output" 2>&1; then fail_test 'interrupted restore unexpectedly succeeded'; fi
[ "$(sed -n '2p' "$selected_backup/patch-journal")" = restoring ] || fail_test 'restore interruption lost recovery state'
[ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] && [ "$(cat "$CASE_ROOT/persistent/config")" = broken-config ] || fail_test 'restore interruption was not between file copies'
: > "$CASE_ROOT/fail-restart"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/restart-output" 2>&1; then fail_test 'failed restart reported complete recovery'; fi
[ "$(sed -n '2p' "$selected_backup/patch-journal")" = restoring ] || fail_test 'failed restart marked rollback complete'
rm "$CASE_ROOT/fail-restart"
sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/retry-output" 2>&1 || fail_test 'fresh-process rollback retry failed'
[ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] && [ "$(cat "$CASE_ROOT/persistent/config")" = old-config ] || fail_test 'retry did not restore runtime and persistent config'
[ -L "$CASE_ROOT/dangling" ] && [ "$(readlink "$CASE_ROOT/dangling")" = missing ] || fail_test 'dangling original symlink was not restored'
[ "$(sed -n '2p' "$selected_backup/patch-journal")" = restored ] || fail_test 'successful restore was not persisted'
[ "$(tail -n 1 "$CASE_ROOT/restores")" = stopped ] || fail_test 'saved service state was not reloaded'
restores_before="$(wc -l < "$CASE_ROOT/restores")"
sh -c '. "$FIXTURE"; recover_interrupted_patch' > "$CASE_ROOT/noop-output" 2>&1 || fail_test 'repeated recovery failed'
[ "$(wc -l < "$CASE_ROOT/restores")" = "$restores_before" ] || fail_test 'completed rollback repeated service mutation'

# A syntactically valid generation field is still opaque data, even when the
# package-generation boundary returns that exact unusual string.
new_case opaque-generation
printf '$(touch "%s/injected")\n' "$CASE_ROOT" > "$CASE_ROOT/generation"
sh -c '. "$FIXTURE"; backup_runtime; printf broken > "$CASE_ROOT/runtime"' > "$CASE_ROOT/output" 2>&1 || fail_test 'opaque generation fixture failed'
sh -c '. "$FIXTURE"; recover_interrupted_patch' >> "$CASE_ROOT/output" 2>&1 || fail_test 'opaque generation recovery failed'
[ ! -e "$CASE_ROOT/injected" ] && [ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] || fail_test 'generation data executed as shell'

new_case deferred-services
sh -c '. "$FIXTURE"; PODKOP_PATCH_DEFER_SERVICE_START=1; backup_runtime; printf broken > "$CASE_ROOT/runtime"' > "$CASE_ROOT/output" 2>&1 || fail_test 'deferred fixture failed'
sh -c '. "$FIXTURE"; PODKOP_PATCH_DEFER_SERVICE_START=0; recover_interrupted_patch; [ "$PODKOP_PATCH_DEFER_SERVICE_START" = 0 ]' >> "$CASE_ROOT/output" 2>&1 || fail_test 'deferred recovery did not resume caller policy'
[ "$(cat "$CASE_ROOT/restored-defer")" = 1 ] || fail_test 'recovery lost saved service-start deferral'

# Symlink targets ending in newlines remain distinct after serialization.
new_case newline-link-target
rm "$CASE_ROOT/dangling"
newline_target="$(printf 'missing\n.')"
newline_target="${newline_target%.}"
ln -s "$newline_target" "$CASE_ROOT/dangling"
sh -c '. "$FIXTURE"; backup_runtime; printf "%s\n" "$backup_dir" > "$CASE_ROOT/selected-backup"' > "$CASE_ROOT/output" 2>&1 || fail_test 'newline target snapshot failed'
newline_backup="$(cat "$CASE_ROOT/selected-backup")"
newline_link="$newline_backup/patch-rollback/${CASE_ROOT#/}/dangling"
rm "$newline_link"
newline_target="$(printf 'missing\n\n.')"
newline_target="${newline_target%.}"
ln -s "$newline_target" "$newline_link"
if sh -c '. "$FIXTURE"; recover_interrupted_patch' >> "$CASE_ROOT/output" 2>&1; then fail_test 'newline-distinct symlink target accepted'; fi
[ ! -e "$CASE_ROOT/restores" ] || fail_test 'newline target mismatch changed service state'

new_case newline-member
newline_member="$(printf 'member\nname')"
printf content > "$CASE_ROOT/persistent/$newline_member"
if sh -c '. "$FIXTURE"; backup_runtime; printf mutated > "$CASE_ROOT/runtime"' > "$CASE_ROOT/output" 2>&1; then fail_test 'newline snapshot member name allowed ambiguous inventory'; fi
[ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] || fail_test 'newline member refusal changed runtime'

# Unsupported metadata measurement fails closed before patch writes.
new_case unreadable-mode
if sh -c '. "$FIXTURE"; stat() { return 1; }; backup_runtime; printf mutated > "$CASE_ROOT/runtime"' > "$CASE_ROOT/output" 2>&1; then fail_test 'unreadable snapshot mode allowed patch writes'; fi
[ "$(cat "$CASE_ROOT/runtime")" = old-runtime ] || fail_test 'unreadable mode changed live runtime'

# A committed patch must survive a new installer process without rollback.
new_case committed
sh -c '. "$FIXTURE"; backup_runtime; printf installed > "$CASE_ROOT/runtime"; write_patch_journal committed' > "$CASE_ROOT/output" 2>&1 || fail_test 'commit fixture failed'
sh -c '. "$FIXTURE"; recover_interrupted_patch' >> "$CASE_ROOT/output" 2>&1 || fail_test 'committed journal rejected'
[ "$(cat "$CASE_ROOT/runtime")" = installed ] && [ ! -e "$CASE_ROOT/restores" ] || fail_test 'commit was rolled back'

new_case pruning
sh -c '. "$FIXTURE"; backup_runtime; printf "%s\n" "$backup_dir" > "$CASE_ROOT/pending"' > "$CASE_ROOT/output" 2>&1
pending="$(cat "$CASE_ROOT/pending")"
mkdir "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-bad" "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-old" "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-new"
printf 'malformed\n' > "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-bad/patch-journal"
touch -t 200001010000 "$pending" "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-bad" "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-old"
touch -t 200101010000 "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-new"
sh -c '. "$FIXTURE"; BACKUPS_KEEP=1; cleanup_old_backups' >> "$CASE_ROOT/output" 2>&1
[ -d "$pending" ] && [ -d "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-bad" ] || fail_test 'cleanup removed unresolved or malformed recovery data'
[ ! -e "$CASE_ROOT/backups/podkop-patch-subscriptions-backup-old" ] || fail_test 'cleanup stopped pruning resolved old backups'

flow="$test_root/main-flow"
sed -n '/^tmp_dir="$(mktemp -d)"$/,$p' "$repo_root/i" > "$flow"
lock_line="$(grep -n '^installer_mutation_lock_acquire ||' "$flow" | cut -d: -f1)"
recover_line="$(grep -n '^recover_interrupted_patch ||' "$flow" | cut -d: -f1)"
fetch_line="$(grep -n '^prefetch_patch_assets$' "$flow" | cut -d: -f1)"
[ "$lock_line" -lt "$recover_line" ] && [ "$recover_line" -lt "$fetch_line" ] || fail_test 'recovery is not locked and before fresh downloads/mutations'
commit_line="$(grep -n '^write_patch_journal committed ||' "$flow" | cut -d: -f1)"
success_line="$(grep -n '^log "Installed' "$flow" | cut -d: -f1)"
[ "$commit_line" -lt "$success_line" ] || fail_test 'installation reports success before durable commit'

printf '%s\n' 'PASS: patch space gate and data-only recovery survive interruption, refusal, retry and pruning'
