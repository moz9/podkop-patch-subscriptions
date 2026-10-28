#!/bin/sh
# Generated library supplies dynamic callbacks/globals; A && B || fail asserts
# that both conditions hold and intentionally fails if either is false.
# shellcheck disable=SC1091,SC2034,SC2317,SC2015
set -eu
repo="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sed '/^# CORE_MAIN$/,$d' "$repo/openwrt/podkop-core-compat" > "$work/lib"
cat > "$work/runner" <<'EOF'
#!/bin/sh
set -eu
. "$1/lib"
CORE_ROOT="$1/$2"; CORE_WORK="$CORE_ROOT/root/podkop-core-compat.abcdef"
CORE_ACTION_DIR="$CORE_ROOT/lock"; CORE_ACTION_FILE="$CORE_ROOT/legacy-lock"
CORE_SHA256="$(cat "$CORE_ROOT/candidate.sha256")"
fixture_base="$1"; fixture_name="$2"; fixture_parent="$3"
core_procd_identity() {
 if [ -f "$CORE_ROOT/wrong-boot" ]; then echo 'ffffffff-1234-1234-1234-abcdefabcdef 1'
 else echo 'abcdefab-1234-1234-1234-abcdefabcdef 1'; fi
}
mv() {
 for fixture_target do :; done
 if [ -f "$CORE_ROOT/kill-owner-before-rename" ] && [ "$fixture_target" = "$CORE_ACTION_DIR/owner" ]; then
  rm "$CORE_ROOT/kill-owner-before-rename"; touch "$CORE_ROOT/owner-write-interrupted"; kill -KILL "$$"
 fi
 /bin/mv "$@" || return 1
 if [ -f "$CORE_ROOT/kill-return" ] && [ "$fixture_target" = "$CORE_ACTION_DIR/owner" ] &&
    [ "$(awk 'NR==1{print $1}' "$CORE_ACTION_DIR/owner")" = "$fixture_parent" ]; then
  rm "$CORE_ROOT/kill-return"; touch "$CORE_ROOT/return-interrupted"; kill -KILL "$$"
 fi
}
core_service_action() {
 [ "$1" = restart ] || return 1
 sh "$fixture_base/runner" "$fixture_base" "$fixture_name" "$fixture_parent" & fixture_child=$!
}
touch() {
 command touch "$@" || return 1
 for fixture_target do
  if [ -f "$CORE_ROOT/kill-after-marker" ] && [ "$fixture_target" = "$CORE_WORK/lock-released" ]; then
   rm "$CORE_ROOT/kill-after-marker"
   kill -KILL "$$"
  fi
 done
}
# OS boundaries only: restart/loaded-exe status and wall clock. All coordinator,
# receipts, actual filesystem swap, preservation and rollback are production code.
core_runtime_binding() {
 [ "$(core_hash "$CORE_ROOT/usr/bin/sing-box")" = "$1" ] || return 1
 printf '101 7 %s\n' "$1"
}
core_restart() {
 if [ -f "$CORE_ROOT/hold-restart" ] && [ "$(core_hash "$CORE_ROOT/usr/bin/sing-box")" = "$CORE_SHA256" ]; then
  touch "$CORE_ROOT/restart-entered"
  while [ -f "$CORE_ROOT/hold-restart" ]; do /bin/sleep .01; done
 fi
 [ ! -f "$CORE_ROOT/fail-new" ] || [ "$(core_hash "$CORE_ROOT/usr/bin/sing-box")" != "$CORE_SHA256" ]
}
core_health() {
 CORE_HEALTH_RUNTIME=fixture-stable-generation
 [ ! -f "$CORE_ROOT/fail-all-health" ] || return 1
 [ "$(core_hash "$CORE_ROOT/usr/bin/sing-box")" = "${1:-$CORE_SHA256}" ] || return 1
 core_snapshot > "$CORE_WORK/after.sha256" || return 1
 cmp -s "$CORE_WORK/protected.sha256" "$CORE_WORK/after.sha256"
}
uci() { return 0; }
sleep() { /bin/sleep .01; }
case "${4:-guard}" in
 guard) core_guard "$CORE_WORK" "$3" ;;
 recover) core_recover "$CORE_WORK"; [ -z "${fixture_child:-}" ] || wait "$fixture_child" ;;
esac
EOF
prepare() {
 name="$1"; owner_pid="${2:-$$}"; root="$work/$name"; tx="$root/root/podkop-core-compat.abcdef"
 mkdir -p "$tx" "$root/usr/bin" "$root/etc/config" "$root/etc/sing-box" "$root/etc/init.d" "$root/lock"
 echo unchanged-dns > "$root/etc/config/podkop"; echo '{"outbounds":[]}' > "$root/etc/sing-box/config.json"
 echo old > "$root/usr/bin/sing-box"; echo candidate > "$tx/sing-box.new"
 ln "$root/usr/bin/sing-box" "$tx/sing-box.before"
 sha256sum "$tx/sing-box.before" | awk '{print $1}' > "$tx/before.sha256"
 printf '101 7 %s\n' "$(cat "$tx/before.sha256")" > "$tx/runtime.before"
 sha256sum "$tx/sing-box.new" | awk '{print $1}' > "$root/candidate.sha256"
 printf '%s installer\n' "$owner_pid" > "$root/lock/owner"; cp "$root/lock/owner" "$root/legacy-lock"
 (. "$work/lib"; CORE_ROOT="$root"; uci() { return 0; }; core_snapshot) > "$tx/protected.sha256"
 (. "$work/lib"; CORE_ROOT="$root"; CORE_WORK="$tx"; CORE_PARENT="$owner_pid"
  CORE_ACTION_DIR="$root/lock"; CORE_ACTION_FILE="$root/legacy-lock"
  core_procd_identity() { echo 'abcdefab-1234-1234-1234-abcdefabcdef 1'; }
  core_new_nonce() { echo '11111111-2222-3333-4444-555555555555'; }
  core_reserve)
 cp "$work/lib" "$tx/transaction.sh"
}
wait_file() { n=0; while [ ! -f "$1" ] && [ "$n" -lt 400 ]; do /bin/sleep .01; n=$((n+1)); done; test -f "$1" || fail "missing receipt $1"; }
run() { sh "$work/runner" "$work" "$name" "$$" & child=$!; wait_file "$tx/guard-ready"; }
finish() { wait_file "$tx/lock-released"; wait "$child"; [ "$(awk '{print $1}' "$root/lock/owner")" = "$$" ] || fail 'lock handoff incomplete'; }
prepare success; run; touch "$tx/activate-request"; finish
[ "$(cat "$tx/result")" = committed ] && [ "$(cat "$root/usr/bin/sing-box")" = candidate ] || fail 'normal guarded activation'
# A normal procd respawn after terminal handoff cannot reacquire the lock or
# roll back a committed core, even if later external DNS health deteriorates.
touch "$root/fail-all-health"
sh "$work/runner" "$work" "$name" "$$"
[ "$(cat "$root/usr/bin/sing-box")" = candidate ] && [ "$(awk '{print $1}' "$root/lock/owner")" = "$$" ] || fail 'terminal respawn mutated core/lock'
prepare startup-failure; touch "$root/fail-new"; run; touch "$tx/activate-request"; finish
[ "$(cat "$tx/result")" = rolled-back ] && [ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'startup failure not recovered'
prepare early-abort; touch "$tx/abort"; run; touch "$tx/activate-request"; finish
[ "$(cat "$tx/result")" = not-activated ] && [ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'abort activated core'
prepare dead-guard; run; kill -KILL "$child"; wait "$child" 2>/dev/null || :
# Real pre-v2 stale-file policy: an empty record is busy, a live PID is busy,
# otherwise unlink it. A restartable guard PID must never be the reservation.
legacy_busy() {
 owner="$(awk 'NR==1{print $1}' "$root/legacy-lock")"
 [ -n "$owner" ] || return 0
 # Windows/MSYS fixture has no real Linux PID 1; the procd identity boundary
 # above models that permanent live process, while all child PIDs are real.
 if [ "$owner" = 1 ] || kill -0 "$owner" 2>/dev/null; then return 0; fi
 rm -f "$root/legacy-lock"; return 1
}
legacy_busy || fail 'dead guard reservation was reclaimed during procd respawn gap'
# Exercise the real current installer consumer as well, not a renamed test lock.
eval "$(sed -n '/^installer_lock_pid_alive() {/,/^installer_exit_handler() {/p' "$repo/i" | sed '$d')"
INSTALLER_ACTION_LOCK_DIR="$root/lock"; INSTALLER_ACTION_LOCK_FILE="$root/legacy-lock"
if installer_mutation_lock_acquire; then fail 'installer reclaimed a supervised reservation'; fi
touch "$tx/activate-request"; /bin/sleep .03
[ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'caller can activate without guard'
# Resume the same transaction as procd would; only dead predecessor ownership
# may be recovered. A candidate was never activated by the caller.
run; finish
[ "$(cat "$tx/result")" = committed ] || fail 'supervised restart did not finish'
prepare death-after-swap; touch "$root/hold-restart"; run; touch "$tx/activate-request"
wait_file "$root/restart-entered"; kill -KILL "$child"; wait "$child" 2>/dev/null || :
rm "$root/hold-restart"; run; finish
[ "$(cat "$tx/result")" = rolled-back ] && [ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'supervisor respawn re-applied interrupted candidate'
prepare failed-recovery; touch "$root/fail-all-health"; run; touch "$tx/activate-request"
wait_file "$tx/result"; wait "$child" 2>/dev/null || :
[ "$(cat "$tx/result")" = recovery-required ] || fail 'failed old-core health falsely labelled rolled-back'
rm "$root/fail-all-health"
sh "$work/runner" "$work" "$name" "$$" recover
[ "$(cat "$tx/result")" = rolled-back ] && [ -f "$tx/lock-released" ] || fail 'exhausted supervisor has no safe recovery'
sh "$work/runner" "$work" "$name" "$$" recover || fail 'terminal recovery is not idempotent'
prepare interrupted-return; touch "$root/kill-return"; run; touch "$tx/activate-request"
wait_file "$root/return-interrupted"; wait "$child" 2>/dev/null || :
legacy_busy || fail 'partial return lost reservation'
touch "$root/fail-all-health"
run; finish
[ "$(cat "$root/usr/bin/sing-box")" = candidate ] && [ "$(cat "$tx/result")" = committed ] || fail 'partial handoff rechecked terminal core'
prepare abandoned-setup
cp "$tx/owner.before" "$root/lock/owner"; cp "$tx/legacy.before" "$root/legacy-lock"
rm "$root/lock/core-reservation"
echo partial > "$root/lock/core-reservation.core-11111111-2222-3333-4444-555555555555"
sh "$work/runner" "$work" "$name" "$$" recover || fail 'abandoned pre-journal setup has no safe recovery'
[ "$(cat "$root/usr/bin/sing-box")" = old ] && [ "$(cat "$tx/result")" = not-activated ] || fail 'setup recovery activated a candidate'
[ ! -e "$root/lock/core-reservation.core-11111111-2222-3333-4444-555555555555" ] || fail 'setup recovery left directory permanently reserved'
prepare foreign-owner
echo '999999 foreign-job' > "$root/lock/owner"
if sh "$work/runner" "$work" "$name" "$$"; then fail 'foreign owner accepted'; fi
[ "$(cat "$root/lock/owner")" = '999999 foreign-job' ] && [ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'foreign owner was overwritten'
prepare wrong-boot; touch "$root/wrong-boot"
cp "$root/lock/owner" "$root/owner.expected"
if sh "$work/runner" "$work" "$name" "$$"; then fail 'reservation survived a different boot/procd identity'; fi
cmp -s "$root/owner.expected" "$root/lock/owner" || fail 'wrong boot changed owner'
prepare wrong-journal
echo 'another nonce/work reservation' > "$root/lock/core-reservation"
if sh "$work/runner" "$work" "$name" "$$"; then fail 'foreign nonce journal accepted'; fi
[ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'foreign nonce activated a core'
prepare atomic-owner; touch "$root/kill-owner-before-rename"
sh "$work/runner" "$work" "$name" "$$" & child=$!
wait_file "$root/owner-write-interrupted"; wait "$child" 2>/dev/null || :
[ "$(awk 'NR==1{print $1}' "$root/lock/owner")" = 1 ] || fail 'interrupted owner write exposed an empty/dead record'
legacy_busy || fail 'interrupted atomic write lost legacy reservation'
run; touch "$tx/activate-request"; finish
sleep 60 & absent_parent=$!
prepare absent-parent "$absent_parent"; touch "$root/hold-restart"
sh "$work/runner" "$work" "$name" "$absent_parent" & child=$!
wait_file "$tx/guard-ready"; touch "$tx/activate-request"; wait_file "$root/restart-entered"
kill "$absent_parent"; wait "$absent_parent" 2>/dev/null || :
kill -KILL "$child"; wait "$child" 2>/dev/null || :
legacy_busy || fail 'installer and guard death lost reservation'
rm "$root/hold-restart"
sh "$work/runner" "$work" "$name" "$absent_parent" & child=$!
wait_file "$tx/lock-released"; wait "$child"
[ "$(cat "$tx/result")" = rolled-back ] && [ "$(cat "$root/usr/bin/sing-box")" = old ] || fail 'orphaned transaction did not recover'
[ ! -e "$root/legacy-lock" ] && [ ! -d "$root/lock" ] || fail 'orphaned reservation never released'
# Observe the marker as the parent does: do NOT wait for the guard to exit or
# finish journal cleanup first. Simulate its death in that exact crash window.
prepare marker-before-journal; touch "$root/kill-after-marker"
run; touch "$tx/activate-request"; wait_file "$tx/lock-released"
printf '# PODKOP_CORE_GUARD=1\n# CORE_WORK=%s\n' "$tx" > "$root/etc/init.d/podkop-core-compat-guard"
(
 . "$work/lib"
 CORE_ROOT="$root"; CORE_ACTION_DIR="$root/lock"; CORE_ACTION_FILE="$root/legacy-lock"
 core_procd_identity() { echo 'abcdefab-1234-1234-1234-abcdefabcdef 1'; }
 core_service_action() { [ "$1" = stop ] && touch "$root/guard-stopped"; }
 core_cleanup_finished_guard
) || fail 'parent could not finish terminal journal cleanup before stopping guard'
wait "$child" 2>/dev/null || :
[ ! -e "$root/lock/core-reservation" ] || fail 'marker allowed guard removal with orphaned reservation journal'
INSTALLER_ACTION_LOCK_DIR="$root/lock"; INSTALLER_ACTION_LOCK_FILE="$root/legacy-lock"
installer_mutation_lock_release
[ ! -d "$root/lock" ] || fail 'matching terminal journal left future installer permanently busy'

# A completed old guard may be cleaned up after another legitimate installer
# acquired the now journal-free lock. Its foreign records must stay untouched.
mkdir "$root/lock"
printf '999999 foreign-job\n' > "$root/lock/owner"; cp "$root/lock/owner" "$root/legacy-lock"
printf '# PODKOP_CORE_GUARD=1\n# CORE_WORK=%s\n' "$tx" > "$root/etc/init.d/podkop-core-compat-guard"
(
 . "$work/lib"
 CORE_ROOT="$root"; CORE_ACTION_DIR="$root/lock"; CORE_ACTION_FILE="$root/legacy-lock"
 core_procd_identity() { echo 'abcdefab-1234-1234-1234-abcdefabcdef 1'; }
 core_service_action() { [ "$1" = stop ]; }
 core_cleanup_finished_guard
) || fail 'completed journal-free guard blocks a later foreign installer'
grep -Fxq '999999 foreign-job' "$root/lock/owner" && grep -Fxq '999999 foreign-job' "$root/legacy-lock" || fail 'completed guard changed later foreign owner'

prepare foreign-terminal-journal
printf 'committed\n' > "$tx/result"; touch "$tx/terminal" "$tx/lock-released"
printf '999999 foreign-job\n' > "$root/lock/owner"; cp "$root/lock/owner" "$root/legacy-lock"
printf '# PODKOP_CORE_GUARD=1\n# CORE_WORK=%s\n' "$tx" > "$root/etc/init.d/podkop-core-compat-guard"
cp "$root/lock/core-reservation" "$root/journal.expected"
if (
 . "$work/lib"
 CORE_ROOT="$root"; CORE_ACTION_DIR="$root/lock"; CORE_ACTION_FILE="$root/legacy-lock"
 core_procd_identity() { echo 'abcdefab-1234-1234-1234-abcdefabcdef 1'; }
 core_service_action() { touch "$root/foreign-guard-stopped"; }
 core_cleanup_finished_guard
); then fail 'terminal marker authorized cleanup over a foreign lock owner'; fi
cmp "$root/journal.expected" "$root/lock/core-reservation" || fail foreign-journal-mutation
[ ! -f "$root/foreign-guard-stopped" ] && [ -f "$root/etc/init.d/podkop-core-compat-guard" ] || fail foreign-lock-guard-disarmed

echo 'PASS: coordinator activation, startup rollback, abort, killed guard, supervised recovery and lock handoff'
