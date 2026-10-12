#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
worker=''
trap '[ -z "$worker" ] || kill -TERM "$worker" 2>/dev/null || true; rm -rf "$work"' EXIT
sed '/^case "$1" in/,$d' "$repo/openwrt/podkop-update-manager" > "$work/library"
cat > "$work/installer" <<'EOF'
#!/bin/sh
sleep 30 &
sleeper=$!
trap 'kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; echo stopped > "$FIXTURE_DIR/stopped"; exit 143' TERM
printf '%s\n' "$$" > "$FIXTURE_DIR/child-pid"
echo ready > "$FIXTURE_DIR/ready"
wait "$sleeper"
EOF
cat > "$work/worker" <<'EOF'
#!/bin/sh
. "$FIXTURE_DIR/library"
perform_update() { run_with_timeout 30 sh "$FIXTURE_DIR/installer"; }
run_worker update
EOF
export FIXTURE_DIR="$work" PODKOP_PATCH_MANAGER_STATE_DIR="$work/state"
sh "$work/worker" > "$work/output" 2>&1 &
worker=$!
n=0
until [ -f "$work/ready" ]; do n=$((n+1)); [ "$n" -lt 100 ] || exit 1; sleep .1; done
child=$(cat "$work/child-pid")
[ -d "$work/state/lock" ]
kill -TERM "$worker"
rc=0; wait "$worker" || rc=$?
worker=''
[ "$rc" -eq 143 ]
[ -f "$work/stopped" ]
! kill -0 "$child" 2>/dev/null
[ ! -d "$work/state/lock" ]
jq -e '.state=="error" and .message=="worker_interrupted"' "$work/state/status.json" >/dev/null
# Successful short work cancels and reaps its watchdog as well.
. "$work/library"
run_with_timeout 30 sh -c 'exit 0'
[ -z "$ACTIVE_PID$ACTIVE_WATCHDOG" ]
rc=0
run_with_timeout 1 sh -c 'trap "exit 0" TERM; sleep 20 & sleeper=$!; trap '\''kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; exit 0'\'' TERM; wait "$sleeper"' || rc=$?
[ "$rc" -eq 124 ] || { echo "FAIL: expired deadline returned $rc"; exit 1; }
echo 'PASS: manager interruption waits for installer exit before lock release; watchdog cancelled'
