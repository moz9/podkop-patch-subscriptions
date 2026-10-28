#!/bin/sh
# Dynamic fixture library is generated below, not a project source include.
# shellcheck disable=SC1091
set -eu
repo="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
test -f "$repo/openwrt/podkop-core-compat" || fail 'normal updater has no Reality core transaction'
sed '/^# CORE_MAIN$/,$d' "$repo/openwrt/podkop-core-compat" > "$tmp/lib"
. "$tmp/lib"
core_valid_work /root/podkop-core-compat.a1B2c3 || fail 'mktemp work path rejected'
if core_valid_work /root/podkop-core-compat.a/../b; then fail 'work path traversal accepted'; fi
[ "$(core_route legacy aarch64 1.12.12 stock)" = update ] || fail 'tested Legacy target not selected'
[ "$(core_route legacy aarch64 1.12.12-pdk-reality1 "$CORE_SHA256")" = current ] || fail 'accepted exact ELF not idempotent'
if core_route legacy aarch64 1.12.12-pdk-reality1 wrong; then fail 'version string spoof accepted'; fi
for args in 'legacy mips 1.12.12 stock' 'legacy aarch64 1.13.0 stock' 'legacy aarch64 1.14.2-pdk-r14 stock' 'pe aarch64 1.12.12 stock'; do
 # Each literal row deliberately expands to four positional arguments.
 # shellcheck disable=SC2086
 if core_route $args; then fail "unsupported core/family accepted: $args"; fi
done
[ "$(core_route pe aarch64 1.14.2-pdk-r14 stock)" = native ] || fail 'PE14 not preserved'
[ "$(core_route pe aarch64 1.13.21-pdk-r11 stock)" = native ] || fail 'PE11 not preserved'
core_require_space 60000 65536 "$CORE_BYTES" || fail 'adequate resources rejected'
if core_require_space 20000 65536 "$CORE_BYTES"; then fail 'insufficient storage accepted'; fi
if core_require_space 60000 20000 "$CORE_BYTES"; then fail 'insufficient memory accepted'; fi
mkdir -p "$tmp/root/etc/config" "$tmp/root/etc/sing-box" "$tmp/root/etc/podkop/section-runtime" "$tmp/root/usr/bin"
CORE_ROOT="$tmp/root"
echo dns > "$CORE_ROOT/etc/config/podkop"
echo '{"dns":{},"outbounds":[{"tag":"main-1-out"}]}' > "$CORE_ROOT/etc/sing-box/config.json"
uci() { [ "$*" = changes ] && return 0; return 1; }
core_snapshot > "$tmp/before"
core_snapshot > "$tmp/after"
cmp "$tmp/before" "$tmp/after" || fail 'stable protected state differs'
cp "$CORE_ROOT/etc/sing-box/config.json" "$tmp/same-config"
rm "$CORE_ROOT/etc/sing-box/config.json"
ln -s "$tmp/same-config" "$CORE_ROOT/etc/sing-box/config.json"
test -L "$CORE_ROOT/etc/sing-box/config.json" || fail 'fixture cannot create config symlink'
if core_snapshot > "$tmp/after"; then fail 'conditional snapshot accepted a config symlink'; fi
rm "$CORE_ROOT/etc/sing-box/config.json"
cp "$tmp/same-config" "$CORE_ROOT/etc/sing-box/config.json"
echo changed >> "$CORE_ROOT/etc/config/podkop"
core_snapshot > "$tmp/after"
if cmp -s "$tmp/before" "$tmp/after"; then fail 'DNS mutation not detected'; fi
echo old > "$CORE_ROOT/usr/bin/sing-box"
mkdir "$tmp/tx"
CORE_WORK="$tmp/tx"
ln "$CORE_ROOT/usr/bin/sing-box" "$CORE_WORK/sing-box.before"
core_hash "$CORE_WORK/sing-box.before" > "$CORE_WORK/before.sha256"
echo candidate > "$CORE_ROOT/usr/bin/new"
CORE_SHA256="$(core_hash "$CORE_ROOT/usr/bin/new")"
mv "$CORE_ROOT/usr/bin/new" "$CORE_ROOT/usr/bin/sing-box"
core_restart() { :; }
core_wait_health() { [ "$(core_hash "$CORE_ROOT/usr/bin/sing-box")" = "$1" ]; }
ln "$CORE_WORK/sing-box.before" "$CORE_ROOT/usr/bin/sing-box.core-restore"
core_rollback
[ "$(cat "$CORE_ROOT/usr/bin/sing-box")" = old ] || fail 'old core not atomically restored'
echo foreign-engine > "$CORE_ROOT/usr/bin/new"
mv "$CORE_ROOT/usr/bin/new" "$CORE_ROOT/usr/bin/sing-box"
if core_rollback; then fail 'rollback overwrote an unowned core/PE engine'; fi
[ "$(cat "$CORE_ROOT/usr/bin/sing-box")" = foreign-engine ] || fail 'foreign engine changed during refused rollback'
echo tampered > "$CORE_WORK/sing-box.before"
if core_rollback; then fail 'tampered rollback accepted'; fi
# A disk/version match must not authorize restarting a different loaded graph.
# Only /proc, UCI/procd and DNS process boundaries are fixtures; activate/health
# admission and the actual filesystem exchange remain production functions.
(
 CORE_ROOT="$tmp/runtime"; CORE_WORK="$CORE_ROOT/tx"
 mkdir -p "$CORE_WORK" "$CORE_ROOT/usr/bin" "$CORE_ROOT/etc/config" "$CORE_ROOT/etc/sing-box" "$CORE_ROOT/proc/901"
 printf old > "$CORE_ROOT/usr/bin/sing-box"
 printf candidate > "$CORE_WORK/sing-box.new"
 cp "$CORE_ROOT/usr/bin/sing-box" "$CORE_ROOT/proc/901/exe"
 old_sha="$(core_hash "$CORE_ROOT/usr/bin/sing-box")"; CORE_SHA256="$(core_hash "$CORE_WORK/sing-box.new")"
 printf '%s\n' "$old_sha" > "$CORE_WORK/before.sha256"
 printf '901 7 %s\n' "$old_sha" > "$CORE_WORK/runtime.before"
 printf '{}\n' > "$CORE_ROOT/etc/sing-box/config.json"
 printf '7\n' > "$CORE_ROOT/birth"
 fixture_pid=901; fixture_config=/etc/sing-box/config.json
 pidof() { printf '%s\n' "$fixture_pid"; }
 core_process_start() { cat "$CORE_ROOT/birth"; }
 uci() { case "$*" in changes) return 0;; '-q get podkop.settings.config_path') printf '%s\n' "$fixture_config";; *) return 1;; esac; }
 ubus() {
  [ "$*" = 'call service list {"name":"sing-box","verbose":true}' ] || return 1
  cat "$CORE_ROOT/procd.json"
  if [ -f "$CORE_ROOT/recycle-pid" ]; then echo 8 > "$CORE_ROOT/birth"; fi
 }
 core_restart() { touch "$CORE_WORK/restarted"; }
 core_wait_health() { return 0; }
 timeout() { shift; "$@"; }
 nslookup() { return 0; }
 printf '{"sing-box":{"instances":{"main":{"running":true,"pid":901,"command":["/usr/bin/sing-box","run","-c","/etc/sing-box/config.json"]}}}}\n' > "$CORE_ROOT/procd.json"
 printf '/usr/bin/sing-box\000run\000-c\000/etc/sing-box/other.json\000' > "$CORE_ROOT/proc/901/cmdline"
 core_snapshot > "$CORE_WORK/protected.sha256"
 if core_activate; then fail 'alternate loaded -c graph reached first restart'; fi
 [ ! -e "$CORE_WORK/restarted" ] && [ ! -e "$CORE_WORK/activated" ] || fail 'runtime refusal happened after mutation'
 [ "$(cat "$CORE_ROOT/usr/bin/sing-box")" = old ] || fail 'runtime refusal replaced the ELF'
 printf '/usr/bin/sing-box\000run\000-c\000/etc/sing-box/config.json\000' > "$CORE_ROOT/proc/901/cmdline"
 [ "$(core_runtime_binding "$old_sha")" = "901 7 $old_sha" ] || fail valid-runtime-binding
 printf '\000' >> "$CORE_ROOT/proc/901/cmdline"
 if core_runtime_binding "$old_sha"; then fail extra-empty-argv; fi
 printf '/usr/bin/sing-box\000run\000-c\000/etc/sing-box/config.json\000' > "$CORE_ROOT/proc/901/cmdline"
 printf old-loaded-inode > "$CORE_ROOT/proc/901/exe"
 if core_runtime_binding "$old_sha"; then fail old-loaded-inode; fi
 cp "$CORE_ROOT/usr/bin/sing-box" "$CORE_ROOT/proc/901/exe"
 fixture_config=/etc/sing-box/other.json
 if core_runtime_binding "$old_sha"; then fail alternate-UCI-config; fi
 fixture_config=/etc/sing-box/config.json; fixture_pid='901 902'
 if core_runtime_binding "$old_sha"; then fail split-runtime; fi
 fixture_pid=901
 printf '/usr/bin/sing-box\000run\000-C\000/etc/sing-box\000' > "$CORE_ROOT/proc/901/cmdline"
 if core_runtime_binding "$old_sha"; then fail directory-config-accepted; fi
 printf '/usr/bin/sing-box\000run\000-c\000/etc/sing-box/config.json\000' > "$CORE_ROOT/proc/901/cmdline"
 cp "$CORE_ROOT/procd.json" "$CORE_ROOT/procd.good"
 sed 's|/etc/sing-box/config.json|/etc/sing-box/other.json|' "$CORE_ROOT/procd.good" > "$CORE_ROOT/procd.json"
 if core_runtime_binding "$old_sha"; then fail alternate-procd-command; fi
 cp "$CORE_ROOT/procd.good" "$CORE_ROOT/procd.json"
 jq '.["sing-box"].instances.peer={running:false,pid:902,command:["/usr/bin/sing-box","run","-C","/etc/sing-box"]}' "$CORE_ROOT/procd.good" > "$CORE_ROOT/procd.json"
 if core_runtime_binding "$old_sha"; then fail multiple-procd-instances; fi
 cp "$CORE_ROOT/procd.good" "$CORE_ROOT/procd.json"
 jq '.["sing-box"].instances.main.pid=902' "$CORE_ROOT/procd.good" > "$CORE_ROOT/procd.json"
 if core_runtime_binding "$old_sha"; then fail mismatched-procd-PID; fi
 cp "$CORE_ROOT/procd.good" "$CORE_ROOT/procd.json"
 touch "$CORE_ROOT/recycle-pid"
 if core_runtime_binding "$old_sha"; then fail recycled-runtime-generation; fi
 rm "$CORE_ROOT/recycle-pid"; echo 7 > "$CORE_ROOT/birth"
 core_activate || fail valid-exact-runtime-activation
 [ -f "$CORE_WORK/restarted" ] || fail valid-activation-no-restart
 if core_health "$CORE_SHA256"; then fail health-accepted-old-loaded-inode; fi
 cp "$CORE_ROOT/usr/bin/sing-box" "$CORE_ROOT/proc/901/exe"
 core_health "$CORE_SHA256" || fail healthy-bound-runtime
 cp "$CORE_ROOT/usr/bin/sing-box" "$CORE_ROOT/candidate.saved"
 printf foreign-disk-engine > "$CORE_ROOT/usr/bin/sing-box"
 if core_health "$CORE_SHA256"; then fail health-accepted-different-on-disk-engine; fi
 cp "$CORE_ROOT/candidate.saved" "$CORE_ROOT/usr/bin/sing-box"
 fixture_config=/etc/sing-box/other.json
 if core_health "$CORE_SHA256"; then fail health-accepted-wrong-working-graph; fi
 fixture_config=/etc/sing-box/config.json
 nslookup() { echo 8 > "$CORE_ROOT/birth"; return 0; }
 if core_health "$CORE_SHA256"; then fail health-accepted-generation-change-during-DNS; fi
 # The two healthy observations must bind the same process generation, not
 # merely two successive processes running the same candidate/config.
 eval "$(sed -n '/^core_wait_health() {$/,/^}$/p' "$tmp/lib")"
 health_generation=0
 core_health() { health_generation=$((health_generation+1)); CORE_HEALTH_RUNTIME="901 $health_generation $CORE_SHA256"; return 0; }
 sleep() { :; }
 if core_wait_health "$CORE_SHA256"; then fail unstable-generation-passed-wait-health; fi
 core_health() { CORE_HEALTH_RUNTIME="901 99 $CORE_SHA256"; return 0; }
 core_wait_health "$CORE_SHA256" || fail stable-generation-rejected
)

echo 'PASS: core channel isolation, exact identity, resource guards, DNS/graph preservation and atomic rollback'
