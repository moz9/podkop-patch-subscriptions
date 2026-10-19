#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
script="$repo/scripts/home-pe-0724-migrate.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -s "$script" ] || fail 'HOME migration coordinator is absent'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
HOME_PE_MIGRATION_LIBRARY_ONLY=1 . "$script"
hm_path() { case "$1" in "$work"/*) printf '%s\n' "$1";; *) printf '%s%s\n' "$work/router" "$1";; esac; }
hm_hostname() { printf 'WBR3000UAX\n'; }
hm_boot_id() { printf '3d63f264-c7fc-4b44-b54c-eddd4ca84264\n'; }
hm_mount_table() { printf '%s /mnt/storage ext4 rw,relatime 0 0\n' "${mount_device:-/dev/sda1}"; }
hm_resource_free() { if [ "$1" = /overlay ]; then printf '%s %s\n' "${overlay_free:-${free_kib:-999999}}" "$(if [ "${inode_dynamic:-0}" = 1 ]; then printf dynamic_ubifs; else printf '%s' "${free_inodes:-99999}"; fi)"; else printf '%s %s\n' "${free_kib:-999999}" "${free_inodes:-99999}"; fi; }
hm_service_guard() { printf '100\t/usr/bin/sing-box\t/etc/sing-box/config.json\n101\t/usr/bin/sing-box\t/etc/podkop/section-runtime/workers/main/worker.json\n102\t/usr/bin/sing-box\t/etc/podkop/section-runtime/workers/GEOBLOCK/worker.json\n'; }
hm_start_watchdog() { return 0; }
hm_watchdog_alive() { return 0; }
hm_global_lock_guard() { return 0; }
hm_validate_configs() { return 0; }
hm_prove_stopped() { [ "${blocked_owners:-0}" = 0 ]; }
hm_stop_owned() { printf 'stop\n' >> "$work/events"; }
hm_start_owned() {
    # Starting before rules are restored is an actual rollback regression.
    [ "$(cat "$(hm_path /tmp/sing-box/rulesets/main-user-domains-ruleset.json)")" = frozen-rule ] || return 1
    [ "$(cat "$(hm_path /usr/bin/sing-box)")" = old-engine ] || [ "${force_bad_ready:-0}" = 0 ] || return 1
    printf 'start:%s\n' "$(cat "$(hm_path /usr/bin/sing-box)")" >> "$work/events"
}
hm_wait_owned() { [ "${force_bad_ready:-0}" = 0 ]; }
hm_adapter() {
    case "$1" in
        preflight) return 0;;
        install-deferred)
            if [ "$(jq -r '.binaryRelease.enabled // false' "$2")" = true ]; then
                [ ! -e "$(hm_path /usr/bin/sing-box)" ] || return 1
                printf 'released-before-apk\n' >> "$work/events"
            fi
            printf 'install\n' >> "$work/events"
            printf 'new-engine\n' > "$(hm_path /usr/bin/sing-box)"
            [ "${install_fail:-0}" = 0 ] || return 1
            ;;
        verify-installed) [ "$(cat "$(hm_path /usr/bin/sing-box)")" = new-engine ]; ;;
        *) return 1;;
    esac
}
mkdir -p "$work/router/etc/sing-box" "$work/router/etc/config" "$work/router/usr/bin" "$work/router/lib/apk/db" "$work/router/etc/podkop/section-runtime/workers/main" "$work/router/etc/podkop/section-runtime/workers/GEOBLOCK" "$work/router/tmp/sing-box/rulesets" "$work/router/mnt/storage/podkop-pe-migration" "$work/assets"
mkdir -p "$work/router/etc/init.d" "$work/router/usr/lib/podkop"
for core in /usr/bin/podkop /usr/bin/podkop-section-runtime /etc/init.d/podkop /etc/init.d/sing-box /etc/init.d/podkop-section-worker /usr/lib/podkop/section-hooks.sh /lib/apk/db/scripts.tar.gz /lib/apk/db/triggers /lib/apk/db/lock; do printf 'old-core\n' > "$(hm_path "$core")"; done
printf 'old-engine\n' > "$(hm_path /usr/bin/sing-box)"
printf 'old-db\n' > "$(hm_path /lib/apk/db/installed)"
printf 'settings-preserved\n' > "$(hm_path /etc/config/podkop)"
printf 'frozen-rule\n' > "$(hm_path /tmp/sing-box/rulesets/main-user-domains-ruleset.json)"
graph='{"dns":{"servers":[],"rules":[]},"outbounds":[],"route":{"rule_set":[{"type":"local","tag":"main","path":"/tmp/sing-box/rulesets/main-user-domains-ruleset.json"}]}}'
for config in /etc/sing-box/config.json /etc/podkop/section-runtime/logical.json /etc/podkop/section-runtime/frontend.json /etc/podkop/section-runtime/workers/main/worker.json /etc/podkop/section-runtime/workers/GEOBLOCK/worker.json; do printf '%s\n' "$graph" > "$(hm_path "$config")"; done
printf 'adapter-private-fixture\n' > "$work/assets/install-adapter.sh"
chmod 600 "$work/assets/install-adapter.sh"
guard_files='[]'
for path in /etc/config/podkop /etc/sing-box/config.json /etc/podkop/section-runtime/logical.json /etc/podkop/section-runtime/frontend.json /etc/podkop/section-runtime/workers/main/worker.json /etc/podkop/section-runtime/workers/GEOBLOCK/worker.json; do
    digest="$(sha256sum "$(hm_path "$path")"|cut -d ' ' -f1)"
    guard_files="$(printf '%s' "$guard_files"|jq -c --arg p "$path" --arg h "$digest" '.+[{path:$p,sha256:$h}]')"
done
adapter_digest="$(sha256sum "$work/assets/install-adapter.sh"|cut -d ' ' -f1)"
jq -n --argjson guards "$guard_files" --arg adapter "$work/assets/install-adapter.sh" --arg digest "$adapter_digest" '{
  version:1,scope:"HOME-only",hostname:"WBR3000UAX",bootId:"3d63f264-c7fc-4b44-b54c-eddd4ca84264",
  guardFiles:$guards,
  graphPaths:["/etc/sing-box/config.json","/etc/podkop/section-runtime/logical.json","/etc/podkop/section-runtime/frontend.json","/etc/podkop/section-runtime/workers/main/worker.json","/etc/podkop/section-runtime/workers/GEOBLOCK/worker.json"],
  externalDevice:"/dev/sda1",
  writePaths:["/usr/bin/sing-box","/usr/bin/podkop","/usr/bin/podkop-section-runtime","/usr/lib/podkop/section-hooks.sh","/etc/init.d/podkop","/etc/init.d/sing-box","/etc/init.d/podkop-section-worker","/lib/apk/db/installed","/lib/apk/db/scripts.tar.gz","/lib/apk/db/triggers","/lib/apk/db/lock"],writeSetComplete:true,
  constraints:[{path:"/overlay",minFreeKiB:16000,minFreeInodes:2000},{path:"/mnt/storage",minFreeKiB:250000,minFreeInodes:3000}],
  assets:[{path:$adapter,sha256:$digest}],installAdapter:{path:$adapter,sha256:$digest},
  target:{podkop:"0.7.24-r1",engine:"1.14.2-r14"}
}' > "$work/plan.json"
hm_validate_plan "$work/plan.json" || fail 'valid HOME plan rejected'
jq '.writePaths|=map(select(.!="/lib/apk/db/scripts.tar.gz"))' "$work/plan.json" > "$work/incomplete-plan.json"
hm_validate_plan "$work/incomplete-plan.json" && fail 'incomplete package DB rollback accepted' || :
hm_guard "$work/plan.json" || fail 'valid exact HOME guard rejected'
hm_hostname() { printf 'Pioneer\n'; }
hm_guard "$work/plan.json" && fail 'other router accepted' || :
hm_hostname() { printf 'WBR3000UAX\n'; }
hm_boot_id() { printf 'different-boot\n'; }
hm_guard "$work/plan.json" && fail 'reboot accepted' || :
hm_boot_id() { printf '3d63f264-c7fc-4b44-b54c-eddd4ca84264\n'; }
free_inodes=1
hm_guard "$work/plan.json" && fail 'inode exhaustion accepted' || :
free_inodes=99999
free_kib=1
hm_guard "$work/plan.json" && fail 'space exhaustion accepted' || :
free_kib=999999
inode_dynamic=1
hm_guard "$work/plan.json" && fail 'dynamic inode policy was implicitly invented' || :
jq '.constraints|=map(if .path=="/overlay" then .minFreeInodes=0|.inodePolicy="ubifs_dynamic" else . end)' "$work/plan.json" > "$work/dynamic-plan.json"
hm_guard "$work/dynamic-plan.json" || fail 'explicit verified UBIFS dynamic inode policy refused'
inode_dynamic=0
mount_device=/dev/sdb1
hm_guard "$work/plan.json" && fail 'external storage identity changed' || :
mount_device=/dev/sda1
printf 'changed\n' >> "$(hm_path /etc/config/podkop)"
hm_guard "$work/plan.json" && fail 'desired settings drift accepted' || :
printf 'settings-preserved\n' > "$(hm_path /etc/config/podkop)"
tx="$(hm_prepare "$work/plan.json")" || fail 'snapshot prepare failed'
[ -s "$tx/rollback/tmp/sing-box/rulesets/main-user-domains-ruleset.json" ] || fail 'ephemeral rules were not frozen'
[ "$(cat "$tx/rollback/usr/bin/sing-box")" = old-engine ] || fail 'old binary not frozen'
hm_apply "$tx" && fail 'missing local archive receipt accepted' || :
[ ! -f "$work/events" ] || fail 'missing receipt caused service mutation'
archive_sha="$(sha256sum "$tx/rollback.tar"|cut -d ' ' -f1)"
jq -n --arg sha "$archive_sha" --arg boot '3d63f264-c7fc-4b44-b54c-eddd4ca84264' '{version:1,verifiedLocalArchiveSha256:$sha,bootId:$boot}' > "$tx/local-copy-receipt.json"
install_fail=1
hm_apply "$tx" && fail 'failed install reported success' || :
[ "$(cat "$(hm_path /usr/bin/sing-box)")" = old-engine ] || fail 'old engine was not restored'
[ "$(cat "$(hm_path /lib/apk/db/installed)")" = old-db ] || fail 'old package DB was not restored'
jq -e '.phase=="rolled_back"' "$tx/state.json" >/dev/null || fail 'rollback state was not recorded'
# A missing /tmp dataset must be restored BEFORE any old-code restart.
rm "$(hm_path /tmp/sing-box/rulesets/main-user-domains-ruleset.json)"
rmdir "$(hm_path /tmp/sing-box/rulesets)" "$(hm_path /tmp/sing-box)"
hm_rollback "$tx" || fail 'bounded rollback failed'
[ "$(cat "$(hm_path /tmp/sing-box/rulesets/main-user-domains-ruleset.json)")" = frozen-rule ] || fail 'rules were not restored'
install_fail=0
tx2="$(hm_prepare "$work/plan.json")"
archive_sha="$(sha256sum "$tx2/rollback.tar"|cut -d ' ' -f1)"
jq -n --arg sha "$archive_sha" --arg boot '3d63f264-c7fc-4b44-b54c-eddd4ca84264' '{version:1,verifiedLocalArchiveSha256:$sha,bootId:$boot}' > "$tx2/local-copy-receipt.json"
hm_apply "$tx2" || fail 'verified frozen-graph activation failed'
[ "$(cat "$(hm_path /usr/bin/sing-box)")" = new-engine ] || fail 'new engine not retained'
[ "$(cat "$(hm_path /etc/config/podkop)")" = settings-preserved ] || fail 'user settings changed'
jq -e '.phase=="activated"' "$tx2/state.json" >/dev/null || fail 'success state not recorded'
hm_confirm "$tx2" && fail 'external verification receipt was not required' || :
jq -n --arg boot '3d63f264-c7fc-4b44-b54c-eddd4ca84264' --argjson now "$(date +%s)" '{version:1,bootId:$boot,checkedAt:$now,clientDns:true,workerHttps:true,stablePids:true,pids:[100,101,102]}' > "$tx2/external-verification.json"
hm_confirm "$tx2" || fail 'explicit externally verified confirmation failed'
hm_watchdog_tick "$tx2" 100 200 || fail 'confirmed watchdog state failed'
jq -e '.phase=="confirmed"' "$tx2/state.json" >/dev/null || fail 'confirmed transaction watchdog rolled back'
hm_apply "$tx2" && fail 'completed transaction replay accepted' || :
hm_rollback "$tx2" || fail 'restoring old version for release test failed'
old_sha="$(sha256sum "$(hm_path /usr/bin/sing-box)"|cut -d ' ' -f1)"
old_size="$(wc -c < "$(hm_path /usr/bin/sing-box)")"
jq --arg old "$old_sha" --argjson bytes "$old_size" '.binaryRelease={enabled:true,path:"/usr/bin/sing-box",oldSha256:$old,oldSizeBytes:$bytes,finalAllocationKiB:4000,minFinalFreeKiB:5000}' "$work/plan.json" > "$work/release-plan.json"
overlay_free=10000
hm_guard "$work/release-plan.json" || fail 'receipt-gated final-fit binary release admission failed'
tx3="$(hm_prepare "$work/release-plan.json")"
archive_sha="$(sha256sum "$tx3/rollback.tar"|cut -d ' ' -f1)"
jq -n --arg sha "$archive_sha" --arg boot '3d63f264-c7fc-4b44-b54c-eddd4ca84264' '{version:1,verifiedLocalArchiveSha256:$sha,bootId:$boot}' > "$tx3/local-copy-receipt.json"
blocked_owners=1
hm_apply "$tx3" && fail 'binary release accepted remaining process owners' || :
[ -f "$(hm_path /usr/bin/sing-box)" ] || fail 'owned binary was unlinked before owner-stop proof'
blocked_owners=0
hm_rollback "$tx3" || fail 'blocked release could not retain/restore old graph'
tx4="$(hm_prepare "$work/release-plan.json")"
archive_sha="$(sha256sum "$tx4/rollback.tar"|cut -d ' ' -f1)"
jq -n --arg sha "$archive_sha" --arg boot '3d63f264-c7fc-4b44-b54c-eddd4ca84264' '{version:1,verifiedLocalArchiveSha256:$sha,bootId:$boot}' > "$tx4/local-copy-receipt.json"
install_fail=1
hm_apply "$tx4" && fail 'post-release install failure reported success' || :
[ "$(cat "$(hm_path /usr/bin/sing-box)")" = old-engine ] || fail 'released binary was not restored before old-code activation'
install_fail=0
unset overlay_free
grep -Fxq released-before-apk "$work/events" || fail 'binary-release branch was never exercised'
# A detached watchdog cannot restore under a package process still holding flock.
tx5="$(hm_prepare "$work/plan.json")"
archive_sha="$(sha256sum "$tx5/rollback.tar"|cut -d ' ' -f1)"
jq -n --arg sha "$archive_sha" --arg boot '3d63f264-c7fc-4b44-b54c-eddd4ca84264' '{version:1,verifiedLocalArchiveSha256:$sha,bootId:$boot}' > "$tx5/local-copy-receipt.json"
hm_apply "$tx5" || fail 'watchdog activation fixture failed'
exec 8> "$tx5/operation.lock"
flock -n 8 || fail 'watchdog fixture could not hold package mutex'
hm_watchdog_tick "$tx5" 100 200 || :
[ -f "$tx5/watchdog.abort" ] || fail 'watchdog did not request recovery for held package mutex'
jq -e '.phase=="activated"' "$tx5/state.json" >/dev/null || fail 'watchdog overwrote concurrently locked transaction'
flock -u 8
hm_watchdog_tick "$tx5" 100 200 || fail 'watchdog deadline rollback failed after mutex release'
jq -e '.phase=="rolled_back"' "$tx5/state.json" >/dev/null || fail 'unconfirmed orphan transaction was not rolled back'
printf 'tampered\n' >> "$tx2/rollback.tar"
hm_rollback "$tx2" && fail 'tampered rollback archive accepted' || :
printf 'PASS: HOME identity/boot/settings/space/inode gates, ephemeral freeze, local receipt, rollback ordering, frozen activation and replay/tamper refusal\n'
