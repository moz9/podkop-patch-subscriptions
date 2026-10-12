#!/bin/bash
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export fixture="$work" signal_repo="$repo"
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$work/optimizer" <<'EOF'
#!/bin/sh
slot="$2"
if [ "$slot" = secondary ] && [ -f "$fixture/reloaded" ] && [ "$signal_stage" = probe ] && [ ! -e "$fixture/fired" ]; then
    touch "$fixture/fired"; kill -TERM "$signal_pid"
fi
if [ "$slot" = primary ] && { { [ "$signal_command" = watch ] && [ ! -e "$fixture/fired" ]; } || { [ "$signal_health" = bad ] && [ -e "$fixture/fired" ]; }; }; then echo '{"success":false}'; else echo '{"success":true}'; fi
EOF
chmod +x "$work/optimizer"
printf '#!/bin/sh\nexit 0\n' > "$work/service"; chmod +x "$work/service"
printf '{}\n' > "$work/runtime.json"
mkdir "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sing-box"; chmod +x "$work/bin/sing-box"
export PATH="$work/bin:$PATH"
cat > "$work/run" <<'EOF'
#!/bin/bash
set -u
eval "$(sed '/^case "${1:-}" in/,$d' "$signal_repo/openwrt/podkop-dns-failover" | sed "s|/etc/init.d/sing-box|$fixture/service|g; s|/tmp/podkop-dns-failover-reload.log|$fixture/reload.log|g")"
OPTIMIZER="$fixture/optimizer"
STATE_DIR="$fixture/state"; STATUS_FILE="$STATE_DIR/status.json"; FAILURE_FILE="$STATE_DIR/failures"
WATCH_LOCK="$STATE_DIR/watch.lock"; SWITCH_LOCK="$STATE_DIR/switch.lock"
PODKOP_MUTATION_LOCK_DIR="$fixture/mutation"; PODKOP_MUTATION_LEGACY_LOCK_FILE="$fixture/legacy"
export signal_pid="$$"
uci() {
    [ "${1:-}" != -q ] || shift
    case "$1" in
      get) case "$2" in *dns_failover_active_slot) cat "$fixture/active";; *dns_failover_enabled|*failure_threshold) echo 1;; sing-box.main.conffile) echo "$fixture/runtime.json";; *) return 1;; esac;;
      set) printf '%s\n' "${2#*=}" > "$fixture/active"; echo "$*" >> "$fixture/mutations"
          if [ "$signal_stage" = exit ] && [ "${2#*=}" = secondary ]; then touch "$fixture/fired"; exit 7; fi;;
      commit) :;;
    esac
}
env() {
    echo reload >> "$fixture/reloads"
    if [ "$(cat "$fixture/active")" = secondary ]; then
        touch "$fixture/reloaded"
        if [ "$signal_stage" = reload ] && [ ! -e "$fixture/fired" ]; then touch "$fixture/fired"; kill -TERM "$signal_pid"; fi
    elif [ -e "$fixture/fired" ]; then
        [ -e "$SWITCH_LOCK" ] && [ -e "$PODKOP_MUTATION_LOCK_DIR" ] && [ -e "$PODKOP_MUTATION_LEGACY_LOCK_FILE" ] || { touch "$fixture/unlocked-too-soon"; return 1; }
        # A second catchable signal must not interrupt restoration.
        kill -TERM "$signal_pid"
        touch "$fixture/rollback-reload"
    fi
}
dig() { echo 198.18.0.1; }
ps() { :; }
logger() { :; }
# Preserve the actual timeout helper and actual switch/watch CLI traps.
if [ "$signal_command" = switch ]; then set -- switch secondary; else set -- watch; fi
eval "$(sed -n '/^case "${1:-}" in/,$p' "$signal_repo/openwrt/podkop-dns-failover")"
EOF
for signal_command in switch watch; do
    for signal_stage in reload probe exit; do
        export signal_command signal_stage signal_health=good
        rm -rf "$work/state"; rm -f "$work/fired" "$work/reloaded" "$work/reloads" "$work/rollback-reload" "$work/unlocked-too-soon"
        printf primary > "$work/active"
        if bash "$work/run" > "$work/result" 2> "$work/errors"; then fail 'interrupted transaction returned success'; fi
        [ -e "$work/fired" ] || fail 'fixture did not send signal'
        [ "$(cat "$work/active")" = primary ] || fail "$signal_command/$signal_stage signal left target committed"
        [ -e "$work/rollback-reload" ] && [ ! -e "$work/unlocked-too-soon" ] || fail 'rollback skipped or locks released before recovery'
        jq -e '.message=="interrupted_rolled_back" and .activeSlot=="primary"' "$work/state/status.json" >/dev/null || fail 'interruption recovery status missing'
        [ ! -e "$work/mutation" ] && [ ! -e "$work/legacy" ] && [ ! -e "$work/state/switch.lock" ] && [ ! -e "$work/state/watch.lock" ] || fail 'signal cleanup leaked locks'
    done
done
export signal_command=switch signal_stage=reload signal_health=bad
rm -rf "$work/state"; rm -f "$work/fired" "$work/reloaded" "$work/rollback-reload"
printf primary > "$work/active"
! bash "$work/run" > "$work/result" 2> "$work/errors" || fail 'unhealthy interrupted recovery returned success'
jq -e '.state=="error" and .message=="interrupted_rollback_failed"' "$work/state/status.json" >/dev/null || fail 'unhealthy recovery claimed healthy rollback'
[ ! -e "$work/mutation" ] && [ ! -e "$work/legacy" ] && [ ! -e "$work/state/switch.lock" ] || fail 'failed interrupted recovery leaked locks'
echo 'PASS: actual switch/watch CLI TERM during reload/probe and unexpected EXIT restores with locks, masks repeated TERM, verifies rollback health'
