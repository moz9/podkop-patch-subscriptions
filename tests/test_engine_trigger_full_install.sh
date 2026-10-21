#!/bin/sh
# Isolated coverage for the full install path of the sources upgrader.
#
# The engine trigger used to be installed only in the restricted recovery
# branch and in the "already installed" early return. A first or a complete
# upgrade went through the bottom path, which stopped after the guarded init
# restart, so the operator's "Save & Apply" event could stay without a
# resident service able to act on it.
#
# The scenario has to reach the bottom path, and that has to be proven rather
# than assumed: a copy of the canonical runtime still satisfies the
# "already installed" predicate, so the fixture removes one specific
# capability the predicate checks, the captured output has to name the bottom
# path, and a mutation that removes only the bottom call has to make this
# test fail.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
upgrade="$repo/openwrt/podkop-subscription-sources-upgrade.sh"
[ -f "$upgrade" ] || fail 'sources upgrade script is missing'
runtime="$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
if [ ! -f "$runtime" ]; then
    set -- "$repo"/openwrt/runtime-*/usr/bin/podkop
    runtime="$1"
fi
[ -f "$runtime" ] || fail 'no canonical runtime available'

# The capability the "already installed" predicate checks. Removing it from
# the target is what forces the bottom path.
CAPABILITY='PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED'
BOTTOM_MESSAGE='Installed subscription source controls and isolated diagnostics.'
ALREADY_MESSAGE='Subscription source controls are already installed.'

make_target() {
    # A previously installed release that misses one specific capability.
    awk -v capability="$CAPABILITY" '
        /^subscription_apply_v2_restore\(\) \{$/ {inside=1}
        inside && index($0, capability) {next}
        {print}
    ' "$runtime" > "$1"
    chmod 755 "$1"
    # An explicit if, not "cmd && fail": under "set -e" a failing left side of
    # an && list aborts the script without a message, which looks like a pass.
    if sed -n '/^subscription_apply_v2_restore() {/,/^}$/p' "$1" | grep -Fq "$CAPABILITY"; then
        fail 'the fixture still carries the capability that forces the bottom path'
    fi
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

engine_has_trigger() {
    grep -Fq 'procd_add_config_trigger "config.change" "podkop"' "$1"
}

# The upgrade script with only the bottom call removed. The last occurrence
# of the call is the one in the bottom path, the earlier ones belong to the
# restricted recovery branch and to the already-installed early return.
make_mutated_upgrade() {
    awk '
        { lines[NR] = $0 }
        /^upgrade_engine_config_change_trigger$/ { last = NR }
        END { for (i = 1; i <= NR; i++) if (i != last) print lines[i] }
    ' "$upgrade" > "$1"
    chmod 755 "$1"
    # The bottom call is the only one at the start of a line: the earlier
    # calls are indented and the definition carries its argument list.
    [ "$(grep -c '^upgrade_engine_config_change_trigger$' "$1")" -eq 0 ] ||
        fail 'the mutation left the bottom call in place'
    [ "$(grep -c '^    upgrade_engine_config_change_trigger$' "$1")" -eq 2 ] ||
        fail 'the mutation removed more than the bottom call'
    grep -Fq "$BOTTOM_MESSAGE" "$1" || fail 'the mutated script lost the bottom path'
}

run_full_path() {
    # $1 upgrade script, $2 target, $3 engine, $4 output file
    PODKOP_SOURCES_SOURCE="$runtime" \
    PODKOP_SOURCES_TARGET="$2" \
    PODKOP_SOURCES_ENGINE_INIT_TARGET="$3" \
        sh "$1" > "$4" 2>&1 || fail 'the full install path failed'
}

# 1. The full path runs and reaches the resident engine trigger.
make_target "$work/target"
make_engine_init "$work/engine"
cp "$work/engine" "$work/engine.once"
run_full_path "$upgrade" "$work/target" "$work/engine" "$work/output"

grep -Fq "$BOTTOM_MESSAGE" "$work/output" ||
    fail "the bottom path did not run, the output names another branch: $(cat "$work/output")"
if grep -Fq "$ALREADY_MESSAGE" "$work/output"; then
    fail 'the scenario still took the already-installed early return'
fi
engine_has_trigger "$work/engine" ||
    fail 'the full install path did not install the engine config.change trigger'
grep -Fq "/etc/init.d/podkop restart 'on_config_change'" "$work/engine" ||
    fail 'the engine trigger does not call the guarded init.d with the apply argument'
sh -n "$work/engine" || fail 'the patched engine init.d is not valid shell'
[ -x "$work/engine" ] || fail 'the patched engine init.d lost the executable bit'
awk '
    /^service_triggers\(\) \{$/ {inside=1; next}
    inside && /^}$/ {inside=0}
    inside && /procd_add_config_trigger "config.change" "podkop"/ {found=1}
    END {exit found?0:1}
' "$work/engine" || fail 'the engine trigger is not registered inside service_triggers()'

# 2. The generation of the engine script from before the upgrade stays
# recoverable, and the backup path is not overwritten by the upgrade.
pristine_md5="$(md5sum "$work/engine.once" | cut -d' ' -f1)"
[ -f "$work/engine.gen-${pristine_md5}" ] || fail 'the pre-upgrade engine generation copy is missing'
cmp "$work/engine.gen-${pristine_md5}" "$work/engine.once" ||
    fail 'the generation copy does not hold the pre-upgrade content'
[ -f "$work/engine.before-engine-trigger" ] || fail 'the write-once backup is missing'
cmp "$work/engine.before-engine-trigger" "$work/engine.once" ||
    fail 'the write-once backup does not hold the pre-upgrade content'

# 3. The scenario is sensitive to the bottom call: removing only that call
# has to leave the engine without the trigger, otherwise the assertions
# above prove nothing about the bottom path.
make_mutated_upgrade "$work/upgrade-mutated"
make_target "$work/target-mutated"
make_engine_init "$work/engine-mutated"
run_full_path "$work/upgrade-mutated" "$work/target-mutated" "$work/engine-mutated" "$work/output-mutated"
grep -Fq "$BOTTOM_MESSAGE" "$work/output-mutated" ||
    fail 'the mutated run did not take the bottom path either'
if engine_has_trigger "$work/engine-mutated"; then
    fail 'the scenario is not sensitive to the bottom call: the mutated script still installed the trigger'
fi

printf 'PASS: the full install path reaches the resident engine trigger\n'
