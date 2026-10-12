#!/bin/bash
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Load actual failover functions without launching its CLI; production file is untouched.
eval "$(sed '/^case "${1:-}" in/,$d' "$repo/openwrt/podkop-dns-failover" | sed "s|/etc/init.d/sing-box|$work/sing-box-init|g; s|/tmp/podkop-dns-failover-reload.log|$work/reload.log|g")"
fail() { echo "FAIL: $*" >&2; exit 1; }
export fixture="$work"
cat > "$work/optimizer" <<'EOF'
#!/bin/sh
slot="$2"
printf '%s\n' "$slot" >> "$fixture/probes"
mode="$(cat "$fixture/probe-mode")"
case "$mode" in
  both-bad) echo '{"success":false}';;
  empty) :;;
  malformed) echo not-json;;
  missing) echo '{}';;
  string) echo '{"success":"true"}';;
  mixed) echo '{"success":true}'; echo '{"success":false}';;
  post-bad|rollback-denied) if [ "$slot" = secondary ] && [ -f "$fixture/reloaded" ]; then echo '{"success":false}'; else echo '{"success":true}'; fi;;
  rollback-bad) if [ -f "$fixture/reloaded" ]; then echo '{"success":false}'; else echo '{"success":true}'; fi;;
  *) echo '{"success":true}';;
esac
EOF
chmod +x "$work/optimizer"
printf '#!/bin/sh\nexit 0\n' > "$work/sing-box-init"; chmod +x "$work/sing-box-init"
printf '{}\n' > "$work/runtime.json"
mkdir "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sing-box"; chmod +x "$work/bin/sing-box"
export PATH="$work/bin:$PATH"
OPTIMIZER="$work/optimizer"
STATE_DIR="$work/state"; STATUS_FILE="$STATE_DIR/status.json"; FAILURE_FILE="$STATE_DIR/failures"
WATCH_LOCK="$STATE_DIR/watch.lock"; SWITCH_LOCK="$STATE_DIR/switch.lock"
PODKOP_MUTATION_LOCK_DIR="$work/mutation"; PODKOP_MUTATION_LEGACY_LOCK_FILE="$work/legacy"
# External boundaries retain persistent state and action evidence.
uci() {
    [ "${1:-}" != -q ] || shift
    case "$1" in
      get) case "$2" in *dns_failover_active_slot) cat "$work/active";; *dns_failover_enabled) echo "${fixture_enabled:-0}";; *dns_failover_failure_threshold) echo 1;; sing-box.main.conffile) echo "$work/runtime.json";; *) return 1;; esac;;
      set) if [ "$(cat "$work/probe-mode")" = rollback-denied ] && [ "${2#*=}" = primary ]; then return 1; fi
          printf '%s\n' "${2#*=}" > "$work/active"; echo "$*" >> "$work/mutations";;
      commit) echo "$*" >> "$work/mutations";;
      *) return 1;;
    esac
}
run_with_timeout() { shift; "$@"; }
env() { echo reload >> "$work/reloads"; touch "$work/reloaded"; return 0; }
dig() { echo 198.18.0.1; }
sleep() { :; }
logger() { :; }
reset_fixture() {
    rm -f "$work/reloaded" "$work/probes" "$work/mutations" "$work/reloads"
    printf primary > "$work/active"; printf '%s' "$1" > "$work/probe-mode"
    ensure_state_dir; write_failure_count 2
}
assert_unlocked() {
    [ ! -e "$SWITCH_LOCK" ] && [ ! -e "$PODKOP_MUTATION_LOCK_DIR" ] && [ ! -e "$PODKOP_MUTATION_LEGACY_LOCK_FILE" ] || fail 'transaction lock leaked'
    ! failover_enabled || fail 'disabled failover was enabled'
}
for mode in empty malformed missing string mixed; do
    reset_fixture "$mode"
    ! probe_slot secondary || fail "zero-exit $mode response accepted"
done
reset_fixture both-bad
! probe_slot primary || fail 'bad primary accepted'
! switch_to_slot secondary automatic || fail 'bad reserve switched'
[ ! -e "$work/mutations" ] && [ ! -e "$work/reloads" ] || fail 'both-bad changed runtime'
assert_unlocked
# One real watcher iteration with an enabled fixture (never production UCI).
( fixture_enabled=1; sleep() { exit 0; }; ps() { :; }; watch_forever )
jq -e '.message=="both_slots_unavailable"' "$STATUS_FILE" >/dev/null || fail 'watcher did not retain both-bad slot'
[ ! -e "$work/mutations" ] && [ ! -e "$work/reloads" ] || fail 'both-bad watcher changed runtime'
[ ! -e "$WATCH_LOCK" ] || fail 'watch lock leaked'
assert_unlocked
reset_fixture good
PODKOP_DNS_BENCHMARK_STATE_DIR="$work/benchmark"
mkdir -p "$PODKOP_DNS_BENCHMARK_STATE_DIR/lock"
( fixture_enabled=1; sleep() { exit 0; }; ps() { :; }; watch_forever )
jq -e '.message=="podkop_operation_running"' "$STATUS_FILE" >/dev/null || fail 'benchmark was counted as DNS failure'
[ ! -e "$work/probes" ] && [ ! -e "$work/mutations" ] && [ ! -e "$work/reloads" ] || fail 'failover interfered with isolated benchmark'
rmdir "$PODKOP_DNS_BENCHMARK_STATE_DIR/lock"
reset_fixture good
mkdir "$PODKOP_MUTATION_LOCK_DIR"; printf '%s fixture\n' "$$" > "$PODKOP_MUTATION_LOCK_DIR/owner"
! switch_to_slot secondary manual || fail 'busy mutation lock ignored'
[ ! -e "$work/mutations" ] || fail 'busy transaction mutated UCI'
jq -e '.message=="podkop_action_busy"' "$STATUS_FILE" >/dev/null
rm "$PODKOP_MUTATION_LOCK_DIR/owner"; rmdir "$PODKOP_MUTATION_LOCK_DIR"
assert_unlocked
reset_fixture good
switch_to_slot secondary manual || fail 'healthy switch failed'
[ "$(cat "$work/active")" = secondary ] || fail 'successful switch not applied'
[ "$(grep -c secondary "$work/probes")" -ge 2 ] || fail 'selected pair not reprobed after reload'
jq -e '.message=="slot_switched" and .lastProbeSuccess==true' "$STATUS_FILE" >/dev/null
assert_unlocked
reset_fixture post-bad
! switch_to_slot secondary manual || fail 'post-reload failed pair accepted'
[ "$(cat "$work/active")" = primary ] || fail 'old slot not restored'
[ "$(wc -l < "$work/reloads")" -eq 2 ] || fail 'rollback not reloaded'
jq -e '.message=="switch_failed_rolled_back"' "$STATUS_FILE" >/dev/null
assert_unlocked
reset_fixture rollback-bad
! switch_to_slot secondary manual || fail 'failed rollback accepted'
jq -e '.state=="error" and .message=="switch_and_rollback_failed"' "$STATUS_FILE" >/dev/null || fail 'unhealthy rollback misreported'
assert_unlocked
reset_fixture rollback-denied
! switch_to_slot secondary manual || fail 'denied UCI rollback accepted'
[ "$(cat "$work/active")" = secondary ] || fail 'rollback-denied fixture did not retain target'
jq -e '.state=="error" and .message=="switch_and_rollback_failed" and .activeSlot=="secondary"' "$STATUS_FILE" >/dev/null || fail 'failed rollback claims previous slot restored'
assert_unlocked
reset_fixture both-bad
! switch_to_slot primary manual || fail 'already-active bad pair accepted'
assert_unlocked
echo 'PASS: failover strict probe contract, both-bad no mutation, post-reload health, rollback health, locks and disabled setting'
