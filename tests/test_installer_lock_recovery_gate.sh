#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
child=''
trap '[ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true; rm -rf "$work"' EXIT
sed '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo/i" > "$work/library"
export PODKOP_PATCH_ACTION_LOCK_FILE="$work/action.lock" PODKOP_PATCH_ACTION_LOCK_DIR="$work/action.lock.d"
export FIXTURE_DIR="$work"
cat > "$work/owner" <<'EOF'
. "$FIXTURE_DIR/library"
installer_mutation_lock_acquire || exit 2
sleep 30 &
echo "$!" > "$FIXTURE_DIR/child"
kill -KILL "$$"
EOF
sh "$work/owner" > "$work/output" 2>&1 && exit 1
child=$(cat "$work/child")
. "$work/library"
owner=$(cat "$INSTALLER_ACTION_LOCK_DIR/owner")
installer_mutation_lock_owned=0
if installer_mutation_lock_acquire; then echo 'FAIL: orphaned writer lock reclaimed'; exit 1; fi
installer_mutation_lock_release
[ "$(cat "$INSTALLER_ACTION_LOCK_DIR/owner")" = "$owner" ]
[ -f "$INSTALLER_ACTION_LOCK_FILE" ]
# Only the test/operator, after stopping the known orphan, clears its fixture lock.
kill -TERM "$child" 2>/dev/null || true
child=''
rm "$INSTALLER_ACTION_LOCK_DIR/owner" "$INSTALLER_ACTION_LOCK_FILE"; rmdir "$INSTALLER_ACTION_LOCK_DIR"
installer_mutation_lock_acquire
installer_mutation_lock_release
[ ! -e "$INSTALLER_ACTION_LOCK_DIR" ] && [ ! -e "$INSTALLER_ACTION_LOCK_FILE" ]
echo 'PASS: killed installer cannot trigger recovery while same-boot writer lock remains'
