#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
upgrade="$repo/openwrt/podkop-subscription-sources-upgrade.sh"
[ -f "$upgrade" ] || fail 'sources upgrade script is missing'
runtime="$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
if [ ! -f "$runtime" ]; then
    set -- "$repo"/openwrt/runtime-*/usr/bin/podkop
    runtime="$1"
fi
[ -f "$runtime" ] || fail 'no canonical runtime available'

# The guarded init.d must apply the desired settings when procd reports a
# configuration change, and must keep the restore-only semantics otherwise.
assert_guarded_init() {
    init="$1"
    grep -Fq '# subscription_safe_init_restart_v1' "$init" || fail 'guarded restart marker is missing'
    grep -Fq '# subscription_config_change_apply_v1' "$init" || fail 'configuration-change branch is missing'
    grep -Fq 'on_config_change' "$init" || fail 'configuration-change argument is not handled'
    grep -Fq '/usr/bin/podkop subscription_config_apply' "$init" ||
        fail 'configuration change bypasses serialized explicit apply'
    grep -Fq '    /usr/bin/podkop restart' "$init" || fail 'routine restart path is missing'
    [ "$(grep -c '^restart() {' "$init")" = "1" ] || fail 'more than one restart implementation'
    sh -n "$init" || fail 'guarded init.d is not valid shell'
    [ -x "$init" ] || fail 'guarded init.d lost the executable bit'
}

# sha256 of a file, with a cmp-based fallback for the busybox hosts.
file_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        cksum "$1" | cut -d' ' -f1
    fi
}

# "uid gid" of a file. The stat applet is not part of the busybox build on
# OpenWrt, so the owner is read from the numeric listing instead.
file_owner() {
    ls -ln "$1" 2>/dev/null | awk 'NR==1 {print $3" "$4}'
}

# Owner preservation can only be proven where the filesystem records a POSIX
# owner and the runner may set a foreign one. Elsewhere the assert would be
# vacuous, so it is reported as not proven instead of silently passing.
owner_proof_available() {
    id -u 2>/dev/null | grep -qx '0' || return 1
    command -v chown >/dev/null 2>&1 || return 1
    : > "$tmp/owner-probe"
    chown nobody "$tmp/owner-probe" 2>/dev/null || return 1
    [ "$(file_owner "$tmp/owner-probe")" != "$(id -u) $(id -g)" ] || return 1
    return 0
}

run_upgrade() {
    init="$1"
    out="${2:-/dev/null}"
    cp "$runtime" "$tmp/runtime"
    PODKOP_SOURCES_SAFE_RESTART_ONLY=1 \
        PODKOP_SOURCES_TARGET="$tmp/runtime" \
        PODKOP_SOURCES_SOURCE="$runtime" \
        PODKOP_SOURCES_INIT_TARGET="$init" \
        sh "$upgrade" >"$out" 2>&1
}

make_upstream_init() {
    cat > "$1" <<'INIT'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/podkop start
    procd_close_instance
}
stop_service() {
    /usr/bin/podkop stop
}
INIT
    chmod 755 "$1"
}

# 1. A fresh upstream init.d without a restart implementation gets the guarded one.
make_upstream_init "$tmp/init-fresh"
chmod 755 "$tmp/init-fresh"
run_upgrade "$tmp/init-fresh"
assert_guarded_init "$tmp/init-fresh"

# 2. An init.d deployed before the configuration-change branch is upgraded, not
#    skipped, and keeps its executable bit and owner.
make_upstream_init "$tmp/init-legacy"
cat >> "$tmp/init-legacy" <<'INIT'

# subscription_safe_init_restart_v1
restart() {
    /usr/bin/podkop restart
}
INIT
chmod 755 "$tmp/init-legacy"
mode_before="$(ls -l "$tmp/init-legacy" | cut -c1-10)"
owner_before="$(file_owner "$tmp/init-legacy")"
if owner_proof_available; then
    # A foreign owner makes the assert meaningful: a plain copy would reset the
    # owner to the runner, a metadata-preserving copy keeps nobody.
    chown nobody "$tmp/init-legacy" || fail 'cannot set a foreign owner on the fixture'
    owner_before="$(file_owner "$tmp/init-legacy")"
    owner_state='foreign owner preserved'
else
    owner_state='not proven: the filesystem does not support a foreign owner'
fi
run_upgrade "$tmp/init-legacy"
assert_guarded_init "$tmp/init-legacy"
grep -Fq '# subscription_config_change_apply_v1' "$tmp/init-legacy" ||
    fail 'legacy guarded init.d was not upgraded to the configuration-change branch'
[ "$(ls -l "$tmp/init-legacy" | cut -c1-10)" = "$mode_before" ] ||
    fail 'upgrade changed the init.d mode'
[ "$(file_owner "$tmp/init-legacy")" = "$owner_before" ] ||
    fail 'upgrade changed the init.d owner'
printf '  owner assert: %s\n' "$owner_state"

# 3. The upgrade is idempotent: a second run must not change the file.
cp "$tmp/init-legacy" "$tmp/init-legacy.once"
run_upgrade "$tmp/init-legacy"
cmp "$tmp/init-legacy" "$tmp/init-legacy.once" || fail 'second upgrade changed the init.d'

# 4. A foreign custom restart implementation is still never replaced.
make_upstream_init "$tmp/init-foreign"
cat >> "$tmp/init-foreign" <<'INIT'
restart() {
    echo custom
}
INIT
chmod 755 "$tmp/init-foreign"
cp "$tmp/init-foreign" "$tmp/init-foreign.once"
cp "$runtime" "$tmp/runtime"
if PODKOP_SOURCES_SAFE_RESTART_ONLY=1 \
    PODKOP_SOURCES_TARGET="$tmp/runtime" \
    PODKOP_SOURCES_SOURCE="$runtime" \
    PODKOP_SOURCES_INIT_TARGET="$tmp/init-foreign" \
    sh "$upgrade" >/dev/null 2>&1; then
    fail 'foreign custom restart implementation was replaced'
fi
cmp "$tmp/init-foreign" "$tmp/init-foreign.once" || fail 'foreign init.d was modified'
grep -Fq 'echo custom' "$tmp/init-foreign" || fail 'foreign restart implementation was modified'
[ -x "$tmp/init-foreign" ] || fail 'foreign init.d lost the executable bit'

# 5. A guarded init.d whose restart body does not call the runtime is refused
#    by the restart-body guard, before any file is staged or swapped.
make_upstream_init "$tmp/init-norestart"
cat >> "$tmp/init-norestart" <<'INIT'

# subscription_safe_init_restart_v1
restart() {
    this is not shell
}
INIT
chmod 755 "$tmp/init-norestart"
cp "$tmp/init-norestart" "$tmp/init-norestart.once"
digest_before="$(file_digest "$tmp/init-norestart")"
if PODKOP_SOURCES_SAFE_RESTART_ONLY=1 \
    PODKOP_SOURCES_TARGET="$tmp/runtime" \
    PODKOP_SOURCES_SOURCE="$runtime" \
    PODKOP_SOURCES_INIT_TARGET="$tmp/init-norestart" \
    sh "$upgrade" >"$tmp/out-norestart" 2>&1; then
    fail 'upgrade accepted a guarded init.d without the runtime restart call'
fi
[ "$(file_digest "$tmp/init-norestart")" = "$digest_before" ] ||
    fail 'the refused init.d was modified'
[ -x "$tmp/init-norestart" ] || fail 'the refused init.d lost the executable bit'
if grep -qiE 'syntax error|unexpected EOF|unexpected end of file|unterminated' "$tmp/out-norestart"; then
    fail 'the restart-body guard did not refuse the file before the syntax check'
fi

# 6. A staged file that is not valid shell must be rejected by the syntax check
#    of the staged file itself. The syntax error has to sit outside the block
#    the upgrade removes, otherwise the staged copy is valid and the rejection
#    would prove nothing.
make_upstream_init "$tmp/init-broken"
cat >> "$tmp/init-broken" <<'INIT'

# subscription_safe_init_restart_v1
restart() {
    /usr/bin/podkop restart
}
INIT
# Break the shell syntax outside the block the upgrade removes: an unclosed
# function is a parse error for every POSIX shell.
cat >> "$tmp/init-broken" <<'INIT'

broken_helper() {
    echo broken
INIT
chmod 755 "$tmp/init-broken"
cp "$tmp/init-broken" "$tmp/init-broken.once"
digest_before="$(file_digest "$tmp/init-broken")"
if PODKOP_SOURCES_SAFE_RESTART_ONLY=1 \
    PODKOP_SOURCES_TARGET="$tmp/runtime" \
    PODKOP_SOURCES_SOURCE="$runtime" \
    PODKOP_SOURCES_INIT_TARGET="$tmp/init-broken" \
    sh "$upgrade" >"$tmp/out-broken" 2>&1; then
    fail 'upgrade accepted a staged file with a shell syntax error'
fi
grep -qiE 'syntax error|unexpected EOF|unexpected end of file|unterminated' "$tmp/out-broken" ||
    fail 'the staged file was rejected without a shell syntax diagnostic'
[ "$(file_digest "$tmp/init-broken")" = "$digest_before" ] ||
    fail 'the init.d with a syntax error was replaced'
[ -x "$tmp/init-broken" ] || fail 'the init.d with a syntax error lost the executable bit'
if ls "$tmp"/init-broken.sources-restart.* >/dev/null 2>&1; then
    fail 'the rejected upgrade left a staged file behind'
fi

echo 'OK: configuration-change apply is installed, permissions survive, and failures never replace the file.'
