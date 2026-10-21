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

# The engine service owns the running procd instance, so the operator's
# "Save & Apply" event has to be registered there. The podkop init script is
# not resident: its process exits right after the engine is started, procd
# drops the service and the trigger registered by it dies with the service.
assert_engine_trigger() {
    init="$1"
    grep -Fq 'procd_add_config_trigger "config.change" "podkop"' "$init" ||
        fail 'the engine service does not register the podkop config.change trigger'
    grep -Fq "/etc/init.d/podkop restart 'on_config_change'" "$init" ||
        fail 'the engine trigger does not call the guarded init.d with the apply argument'
    sh -n "$init" || fail 'the patched engine init.d is not valid shell'
    [ -x "$init" ] || fail 'the patched engine init.d lost the executable bit'
    # the trigger has to live inside the trigger function, not in a comment
    awk '
        /^service_triggers\(\) \{$/ {inside=1; next}
        inside && /^}$/ {inside=0}
        inside && /procd_add_config_trigger "config.change" "podkop"/ {found=1}
        END {exit found?0:1}
    ' "$init" || fail 'the engine trigger is not registered inside service_triggers()'
}

make_engine_init() {
    cat > "$1" <<'INIT'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

start_service() {
	procd_open_instance main
	procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/config.json
	procd_close_instance
}

service_triggers() {
	procd_open_trigger
	procd_add_interface_trigger "interface.*.up" eth0 /etc/init.d/sing-box restart
	procd_close_trigger
	procd_add_reload_trigger "sing-box"
}
INIT
    chmod 755 "$1"
}

run_upgrade() {
    init="$1"
    engine="$2"
    cp "$runtime" "$tmp/runtime"
    PODKOP_SOURCES_SAFE_RESTART_ONLY=1 \
        PODKOP_SOURCES_TARGET="$tmp/runtime" \
        PODKOP_SOURCES_SOURCE="$runtime" \
        PODKOP_SOURCES_INIT_TARGET="$tmp/init-guard" \
        PODKOP_SOURCES_ENGINE_INIT_TARGET="$engine" \
        sh "$upgrade" >/dev/null 2>&1
}

# 1. The engine service without the trigger gets one, and stays valid.
make_engine_init "$tmp/engine"
cp "$tmp/engine" "$tmp/engine.once"
chmod 755 "$tmp/engine"
make_upstream_guard() {
    cat > "$1" <<'INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
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
make_upstream_guard "$tmp/init-guard"
run_upgrade "$tmp/init-guard" "$tmp/engine"
assert_engine_trigger "$tmp/engine"

# 2. The upgrade is idempotent: a second run must not change the engine script.
cp "$tmp/engine" "$tmp/engine.twice"
run_upgrade "$tmp/init-guard" "$tmp/engine"
cmp "$tmp/engine" "$tmp/engine.twice" || fail 'the second upgrade changed the engine init.d'

# 2a. Every generation stays recoverable and no backup path is overwritten.
#     The write-once backup must still hold the state from before the first
#     run, and the content-addressed copy must hold the same content, so a
#     later run can never replace the pristine rollback baseline.
pristine_md5="$(md5sum "$tmp/engine.once" | cut -d' ' -f1)"
generation="$tmp/engine.gen-${pristine_md5}"
[ -f "$generation" ] || fail 'the engine init.d generation copy is missing'
cmp "$generation" "$tmp/engine.once" || fail 'the generation copy does not hold the pre-upgrade content'
[ -x "$generation" ] || fail 'the generation copy lost the executable bit'
[ -f "$tmp/engine.before-engine-trigger" ] || fail 'the write-once backup is missing'
cmp "$tmp/engine.before-engine-trigger" "$tmp/engine.once" || fail 'the write-once backup was overwritten'
cp "$tmp/engine.before-engine-trigger" "$tmp/backup.once"
run_upgrade "$tmp/init-guard" "$tmp/engine"
cmp "$tmp/engine.before-engine-trigger" "$tmp/backup.once" || fail 'a repeated upgrade overwrote the write-once backup'

# 2b. A second, different generation is kept next to the first one.
make_engine_init "$tmp/engine.two"
printf '%s\n' '# a different generation' >> "$tmp/engine.two"
cp "$tmp/engine.two" "$tmp/engine.two.once"
run_upgrade "$tmp/init-guard" "$tmp/engine.two"
second_md5="$(md5sum "$tmp/engine.two.once" | cut -d' ' -f1)"
[ -f "$tmp/engine.two.gen-${second_md5}" ] || fail 'the second generation copy is missing'
[ -f "$tmp/engine.gen-${pristine_md5}" ] || fail 'the first generation copy was removed by the second run'

# 3. An engine script without a trigger function is left untouched.
make_engine_init "$tmp/engine-nofn"
awk '/^service_triggers\(\) \{$/{skip=1} skip&&/^}$/{skip=0;next} !skip{print}' "$tmp/engine-nofn" > "$tmp/engine-nofn.new"
mv "$tmp/engine-nofn.new" "$tmp/engine-nofn"
chmod 755 "$tmp/engine-nofn"
cp "$tmp/engine-nofn" "$tmp/engine-nofn.once"
run_upgrade "$tmp/init-guard" "$tmp/engine-nofn"
cmp "$tmp/engine-nofn" "$tmp/engine-nofn.once" || fail 'an engine script without service_triggers() was modified'
sh -n "$tmp/engine-nofn" || fail 'an engine script without service_triggers() became invalid'

echo 'OK: the operator config change reaches podkop through the resident engine service.'
