#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
pid=''
cleanup() { [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/release" "$work/outside"
printf sentinel > "$work/outside/i"
ln -s "$work/outside" "$work/update"
cp -a "$repo/openwrt" "$work/release/"
cat > "$work/release/i" <<'EOF'
#!/bin/sh
trap 'echo stopped > "$FIXTURE_DIR/stopped"; exit 143' TERM INT HUP
echo "$$" > "$FIXTURE_DIR/installer-pid"
echo ready > "$FIXTURE_DIR/ready"
sleep 30 &
wait "$!"
EOF
hash=$(sha256sum "$work/release/i" | awk '{print $1}')
jq --arg hash "$hash" '.sha256.i=$hash' "$work/release/openwrt/update-manifest.json" > "$work/manifest"
cp "$work/manifest" "$work/release/openwrt/update-manifest.json"
export FIXTURE_DIR="$work"
export PODKOP_PATCH_RAW_ROOT="file://$work/release" PODKOP_PATCH_SAFE_WORK_DIR="$work/update" PODKOP_PATCH_SAFE_LOG="$work/log" PODKOP_PATCH_SAFE_STATUS="$work/status" PODKOP_PATCH_SAFE_FOREGROUND=1
sh "$repo/s" > "$work/output" 2>&1 &
pid=$!
n=0
until [ -e "$work/ready" ]; do
 n=$((n+1)); [ "$n" -lt 100 ] || { cat "$work/output" "$work/log"; echo 'FAIL: stage did not start'; exit 1; }
 sleep .1
done
installer_pid=$(cat "$work/installer-pid")
[ -d "$work/update.lock" ]
if sh "$repo/s" > "$work/contender" 2>&1; then echo 'FAIL: staging concurrently accepted'; exit 1; fi
kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
pid=''
[ "$rc" -eq 143 ] || { echo "FAIL: signal exit was $rc"; exit 1; }
[ -f "$work/stopped" ] || { echo 'FAIL: installer did not receive interruption'; exit 1; }
! kill -0 "$installer_pid" 2>/dev/null || { echo 'FAIL: installer outlived staging lock'; exit 1; }
grep -q '^failed .*reason=interrupted$' "$work/status"
[ ! -d "$work/update.lock" ] || { echo 'FAIL: owned staging lock retained after clean exit'; exit 1; }
[ "$(cat "$work/outside/i")" = sentinel ] || { echo 'FAIL: predictable symlink was followed'; exit 1; }
echo 'PASS: foreground interruption stops owned installer before releasing staging lock'
