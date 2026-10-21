#!/bin/sh
set -eu
target="${PODKOP_SOURCES_TARGET:-/usr/bin/podkop}"
source_runtime="${PODKOP_SOURCES_SOURCE:?canonical runtime is required}"
work="$(mktemp -d /tmp/podkop-sources-upgrade.XXXXXX)"
staged="${target}.sources.$$"
trap 'rm -rf "$work"; rm -f "$staged"' EXIT INT TERM HUP
[ -f "$target" ] && [ -f "$source_runtime" ]
sh -n "$source_runtime"
# Keep every generation of an init script. The write-once backup protects the
# oldest pristine copy, while the content-addressed copy keeps exactly the
# state that existed before this run. A backup path is never overwritten, so a
# later run cannot destroy the rollback baseline of an earlier one and every
# generation stays individually recoverable.
#
# A generation is only called recoverable when it is a regular, non-symlink
# file whose content still matches the hash in its own name. A truncated or
# replaced copy is refused instead of being accepted, and an unusable hash
# tool is an explicit refusal too: an unverifiable backup must not be passed
# off as a rollback baseline.
init_file_hash() {
    local source="$1" out
    if command -v md5sum >/dev/null 2>&1; then
        out="$(md5sum "$source" 2>/dev/null | cut -d' ' -f1)"
        if [ "${#out}" = 32 ] && ! printf '%s' "$out" | grep -q '[^a-f0-9]'; then
            printf '%s' "$out"
            return 0
        fi
    fi
    return 1
}
backup_init_generation() {
    local source="$1" generation sum copied
    [ -f "$source" ] && [ ! -L "$source" ] || return 0
    if ! sum="$(init_file_hash "$source")"; then
        echo "backup_init_generation: no usable md5sum for $source, refusing to claim a backup" >&2
        return 1
    fi
    generation="${source}.gen-${sum}"
    if [ -e "$generation" ] || [ -L "$generation" ]; then
        if [ ! -f "$generation" ] || [ -L "$generation" ]; then
            echo "backup_init_generation: $generation is not a regular file, refusing" >&2
            return 1
        fi
        if ! copied="$(init_file_hash "$generation")"; then
            echo "backup_init_generation: cannot verify $generation, refusing" >&2
            return 1
        fi
        if [ "$copied" != "$sum" ]; then
            echo "backup_init_generation: $generation does not match its own hash, refusing" >&2
            return 1
        fi
        return 0
    fi
    cp -p "$source" "$generation" || return 1
    if ! copied="$(init_file_hash "$generation")"; then
        rm -f "$generation"
        return 1
    fi
    if [ "$copied" != "$sum" ]; then
        echo "backup_init_generation: the copy of $source does not match, refusing" >&2
        rm -f "$generation"
        return 1
    fi
}
# The write-once backup keeps the oldest generation, so its content must not be
# compared with the current file. It still has to be a real, readable file.
backup_init_once() {
    local source="$1" backup
    backup="$2"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        if [ ! -f "$backup" ] || [ -L "$backup" ] || [ ! -s "$backup" ]; then
            echo "backup_init_once: $backup is not a usable regular file, refusing" >&2
            return 1
        fi
        return 0
    fi
    cp -p "$source" "$backup" || return 1
}
upgrade_guarded_init_restart_body() {
    # procd config.change requests applying committed settings. It is not a
    # proof of a human click; authenticated automation may emit it too. The
    # backend serializes, deduplicates and validates admission before restart.
    # Routine restart/reload keeps exact-admission continuity semantics.
    printf '\n%s\n' \
        '# subscription_safe_init_restart_v1' \
        '# subscription_config_change_apply_v1' \
        'restart() {' \
        '    if [ "${1:-}" = "on_config_change" ]; then' \
        '        exec /usr/bin/podkop subscription_config_apply' \
        '    fi' \
        '' \
        '    /usr/bin/podkop restart' \
        '}'
}
upgrade_guarded_init_restart_replace() {
    local init_target="$1" init_staged init_backup
    init_staged="$init_target.sources-restart.$$"
    [ ! -e "$init_staged" ] && [ ! -L "$init_staged" ] || return 1
    # Keep the original mode and owner: the init script has to stay executable.
    # cp -p creates the staged file with the source metadata, and the redirection
    # below only truncates it, so the permissions survive the replacement.
    cp -p "$init_target" "$init_staged" || return 1
    awk '
        /^# subscription_safe_init_restart_v1$/ {skip=1; next}
        skip && /^restart\(\) \{$/ {body=1; next}
        body && /^}$/ {skip=0; body=0; next}
        body {next}
        !skip {print}
    ' "$init_target" > "$init_staged" || { rm -f "$init_staged"; return 1; }
    upgrade_guarded_init_restart_body >> "$init_staged" || { rm -f "$init_staged"; return 1; }
    if ! sh -n "$init_staged"; then rm -f "$init_staged"; return 1; fi
    init_backup="${init_target}.before-sources-restart"
    backup_init_generation "$init_target" || { rm -f "$init_staged"; return 1; }
    backup_init_once "$init_target" "$init_backup" || { rm -f "$init_staged"; return 1; }
    mv "$init_staged" "$init_target"
}
upgrade_guarded_init_restart() {
    local init_target init_staged init_backup
    init_target="${PODKOP_SOURCES_INIT_TARGET:-}"
    if [ -z "$init_target" ] && [ "$target" = /usr/bin/podkop ]; then init_target=/etc/init.d/podkop; fi
    [ -n "$init_target" ] || return 0
    [ -f "$init_target" ] && [ ! -L "$init_target" ] || return 1
    if grep -Fqx '# subscription_safe_init_restart_v1' "$init_target"; then
        sed -n '/^restart() {$/,/^}$/p' "$init_target" | grep -Fq '/usr/bin/podkop restart' || return 1
        # An init.d deployed before the configuration-change branch existed must
        # be upgraded, otherwise the operator's Save & Apply stays refused and
        # every edited list silently stays pending.
        if ! grep -Fq '/usr/bin/podkop subscription_config_apply' "$init_target"; then
            upgrade_guarded_init_restart_replace "$init_target" || return 1
        fi
        return 0
    fi
    # Never replace a foreign custom restart implementation by assumption.
    ! grep -Eq '^[[:space:]]*restart[[:space:]]*\(\)' "$init_target" || return 1
    grep -Fq 'USE_PROCD=1' "$init_target" && grep -Fq '/usr/bin/podkop start' "$init_target" &&
        grep -Fq '/usr/bin/podkop stop' "$init_target" || return 1
    init_staged="$init_target.sources-restart.$$"
    [ ! -e "$init_staged" ] && [ ! -L "$init_staged" ] || return 1
    cp -p "$init_target" "$init_staged" || return 1
    upgrade_guarded_init_restart_body >> "$init_staged" || { rm -f "$init_staged"; return 1; }
    if ! sh -n "$init_staged"; then rm -f "$init_staged"; return 1; fi
    init_backup="${init_target}.before-sources-restart"
    backup_init_generation "$init_target" || { rm -f "$init_staged"; return 1; }
    backup_init_once "$init_target" "$init_backup" || { rm -f "$init_staged"; return 1; }
    mv "$init_staged" "$init_target"
}
upgrade_engine_config_change_trigger() {
    local engine_init="${PODKOP_SOURCES_ENGINE_INIT_TARGET:-/etc/init.d/sing-box}"
    local engine_staged
    [ -f "$engine_init" ] && [ ! -L "$engine_init" ] || return 0
    grep -Fq 'procd_add_config_trigger "config.change" "podkop"' "$engine_init" && return 0
    grep -Fq 'service_triggers() {' "$engine_init" || return 0
    engine_staged="$engine_init.engine-trigger.$$"
    [ ! -e "$engine_staged" ] && [ ! -L "$engine_staged" ] || return 1
    printf '%s\n' \
        '	# podkop: an operator'"'"'s "Save & Apply" in LuCI commits the podkop UCI' \
        '	# and raises the config.change event for the "podkop" package. The podkop' \
        '	# init script is not a resident procd service: its process exits right' \
        '	# after the engine is started, so procd drops the service and the trigger' \
        '	# registered by it dies with the service. The event then never reaches' \
        '	# podkop and an edited list silently stays pending. The engine service' \
        '	# owns the running instance and stays up, so the trigger registered here' \
        '	# survives and the desired settings are applied.' \
        '	if [ -x /usr/bin/podkop ]; then' \
        '		procd_open_trigger' \
        "		procd_add_config_trigger \"config.change\" \"podkop\" /etc/init.d/podkop restart 'on_config_change'" \
        '		procd_close_trigger' \
        '	fi' > "$work/engine-trigger"
    cp -p "$engine_init" "$engine_staged" || return 1
    awk -v helper="$work/engine-trigger" '
        /^service_triggers\(\) \{$/ && !inserted {
            print
            while ((getline line < helper) > 0) print line
            close(helper)
            inserted=1
            next
        }
        {print}
    ' "$engine_init" > "$engine_staged" || { rm -f "$engine_staged"; return 1; }
    [ "$(grep -c 'procd_add_config_trigger "config.change" "podkop"' "$engine_staged")" = "1" ] || {
        rm -f "$engine_staged"
        return 1
    }
    sh -n "$engine_staged" || { rm -f "$engine_staged"; return 1; }
    backup_init_generation "$engine_init" || { rm -f "$engine_staged"; return 1; }
    backup_init_once "$engine_init" "$engine_init.before-engine-trigger" || { rm -f "$engine_staged"; return 1; }
    mv "$engine_staged" "$engine_init"
}
upgrade_config_apply_runtime() {
    grep -Fqx 'subscription_config_apply() (' "$target" &&
        grep -Fqx 'subscription_config_apply)' "$target" && return 0
    # Restricted retrofit: install only this coordinator, not older copies of
    # DNS/service helpers over a newer live runtime.
    ! grep -Fqx 'subscription_config_apply() (' "$target" || return 1
    sed -n '/^subscription_config_apply() ($/,/^)/p' "$source_runtime" > "$work/config-apply"
    [ -s "$work/config-apply" ] || return 1
    cp -p "$target" "$staged" || return 1
    awk -v helper="$work/config-apply" '
    $0=="# subscription_service_snapshot_v1 end" {
        while((getline line < helper)>0) print line; close(helper); inserted++
    }
    $0=="get_subscription_operation_status)" {
        print "subscription_config_apply)\n    subscription_config_apply\n    ;;"; dispatched++
    }
    {print}
    END {if(inserted!=1 || dispatched!=1)exit 1}
    ' "$target" > "$staged" || return 1
    sh -n "$staged" || return 1
    backup_init_once "$target" "$target.before-config-apply" || return 1
    mv "$staged" "$target"
}
if [ "${PODKOP_SOURCES_SAFE_RESTART_ONLY:-0}" = 1 ]; then
    # Restricted recovery retrofit: never replace subscription/DNS helpers or
    # whole lifecycle functions from a potentially newer canonical runtime.
    if ! grep -Fq '# subscription_safe_restart_v1:' "$target"; then
        [ ! -L "$target" ] && grep -Fqx '# subscription_service_snapshot_v1 end' "$target" || exit 1
        ! grep -Fqx 'subscription_services_restart_prepare() {' "$target" || exit 1
        sed -n '/^subscription_services_restart_prepare() {$/,/^}$/p' "$source_runtime" > "$work/restart-prepare"
        if ! grep -Fqx 'subscription_services_continuity_context_ready() {' "$target"; then
            sed -n '/^subscription_services_continuity_context_ready() {$/,/^}$/p' "$source_runtime" >> "$work/restart-prepare"
        fi
        [ -s "$work/restart-prepare" ] || exit 1
        awk -v helper="$work/restart-prepare" '
        /^start_main\(\) \{$/ {fn="start_main"}
        /^reload\(\) \{$/ {fn="reload"}
        /^restart\(\) \{$/ {fn="restart"}
        fn=="start_main" && $0=="    local skip_list_update_started=0 PODKOP_SERVICE_REUSE_ADMITTED_CONFIG=0" {
            print "    local skip_list_update_started=0 PODKOP_SERVICE_REUSE_ADMITTED_CONFIG=\"${PODKOP_SERVICE_RESTART_CONTINUITY:-0}\""; local_site++; next
        }
        fn=="start_main" && $0=="    if ! subscription_services_preflight; then" {
            print "    if [ \"$PODKOP_SERVICE_REUSE_ADMITTED_CONFIG\" = 1 ]; then"
            print "        subscription_services_snapshot_continuity_prepare || return 1"
            print "        log \"Restarting exact admitted runtime; desired changes remain pending\" warn"
            print "    elif ! subscription_services_preflight; then"; start_site++; next
        }
        (fn=="reload" || fn=="restart") && $0=="    subscription_services_preflight || return 1" {
            if(fn=="restart") print "    # subscription_safe_restart_v1: validate before destructive rc.common stop."
            print "    local PODKOP_SERVICE_RESTART_CONTINUITY=0"
            print "    subscription_services_restart_prepare || return 1"; guards++; next
        }
        $0=="# subscription_service_snapshot_v1 end" {
            while((getline line < helper)>0) print line; close(helper); helper_site++
        }
        {print; if($0=="}") fn=""}
        END {if(local_site!=1 || start_site!=1 || guards!=2 || helper_site!=1) exit 1}
        ' "$target" > "$staged" || exit 1
        sh -n "$staged"
        backup="${PODKOP_SOURCES_BACKUP:-${target}.before-safe-restart}"
        backup_init_once "$target" "$backup" || exit 1
        chmod 755 "$staged"
        mv "$staged" "$target"
    fi
    grep -Fqx 'subscription_services_restart_prepare() {' "$target" || exit 1
    upgrade_config_apply_runtime
    upgrade_guarded_init_restart
    upgrade_engine_config_change_trigger
    echo 'Installed only guarded admitted-runtime restart lifecycle.'
    exit 0
fi
source_capability_current() {
    ! grep -Fqx "$1" "$source_runtime" || grep -Fqx "$1" "$target"
}
if grep -Fqx '# subscription_choices_and_busy_v1' "$target" &&
    grep -Fq '# single_runtime_status_v1' "$target" &&
    grep -Fqx 'subscription_config_apply() (' "$target" &&
    source_capability_current 'subscription_pending_sections_json() {' &&
    source_capability_current 'subscription_pending_mark() {' &&
    source_capability_current 'subscription_pending_clear() {' &&
    source_capability_current '# subscription_optional_selection_v1' &&
    source_capability_current '# subscription_tag_prefix_v1' &&
    source_capability_current '# subscription_probe_diagnostics_v1' &&
    grep -Fqx '# subscription_light_probe_v1' "$target" &&
    grep -Fqx '# subscription_selection_v1' "$target" &&
    grep -Fqx '# subscription_tag_filters_v1' "$target" &&
    grep -Fqx '# subscription_tag_glob_portable_v1' "$target" &&
    grep -Fqx '# subscription_service_filter_v1' "$target" &&
    grep -Fqx '# subscription_game_filter_v1' "$target" &&
    grep -Fqx '# subscription_services_v1 end' "$target" &&
    grep -Fqx '# subscription_gemini_region_v2' "$target" &&
    grep -Fqx '# subscription_probe_context_v2' "$target" &&
    grep -Fqx '# subscription_service_snapshot_v1 end' "$target" &&
    grep -Fqx 'subscription_services_snapshot_continuity_prepare() (' "$target" &&
    grep -Fqx 'subscription_services_restart_prepare() {' "$target" &&
    grep -Fq '# subscription_safe_restart_v1:' "$target" &&
    sed -n '/^start_main() {/,/^}/p' "$target" | grep -Fq 'subscription_services_snapshot_continuity_prepare' &&
    sed -n '/^sing_box_init_config() {/,/^}/p' "$target" | grep -Fq 'subscription_services_snapshot_continuity_prepare' &&
    grep -Fqx '# subscription_source_ruleset_reuse_v1' "$target" &&
    # Country additions and strict admission are capabilities, not version labels.
    # Old v1/v2 markers alone must not skip a retrofit of already-patched routers.
    grep -Fqx 'subscription_exit_country_probe() {' "$target" &&
    grep -Fqx 'subscription_services_google_country_classify() {' "$target" &&
    sed -n '/^subscription_services_catalog() {/,/^}/p' "$target" | grep -Fq '"id":"exit_country"' &&
    sed -n '/^subscription_services_catalog() {/,/^}/p' "$target" | grep -Fq '"id":"google_country"' &&
    sed -n '/^subscription_services_validate() {/,/^}/p' "$target" | grep -Fq 'length<=4 and all(.[]; .=="gemini" or .=="chatgpt" or .=="exit_country" or .=="google_country")' &&
    sed -n '/^set_subscription_sections_enabled() {/,/^}/p' "$target" | grep -Fq 'length<=4 and all(.[]; .=="gemini" or .=="chatgpt" or .=="exit_country" or .=="google_country")' &&
    sed -n '/^subscription_source_policy() {/,/^}/p' "$target" | grep -Fq 'command -v subscription_services_country_map' &&
    [ "$(sed -n '/^subscription_source_policy() {/,/^}/p' "$target" | grep -Fc '$proof.declaredCountry==google_declared($item.name // $item.tag // "")')" -eq 2 ] &&
    [ "$(sed -n '/^subscription_source_policy() {/,/^}/p' "$target" | grep -Fc '$proof.expiresAt>$now and $proof.expiresAt<=($proof.checkedAt+86400)')" -eq 2 ] &&
    sed -n '/^subscription_services_read() {/,/^}/p' "$target" | grep -Fq '(.key!="google_country" and .key!="exit_country") or (.value | fresh)' &&
    grep -Fqx 'subscription_services_check)' "$target" &&
    sed -n '/^set_subscription_links_enabled() {/,/^}/p' "$target" | grep -q 'set_subscription_sections_enabled' &&
    sed -n '/^subscription_apply_v2_restore() {/,/^}/p' "$target" | grep -Fq 'PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED' &&
    grep -Eq '^# subscription_isolated_probe_v[12] end$' "$target"; then
    echo 'Subscription source controls are already installed.'
    upgrade_guarded_init_restart
    upgrade_engine_config_change_trigger
    exit 0
fi
for block in subscription_sources_v1 subscription_isolated_probe_v1 subscription_services_v1 subscription_service_snapshot_v1; do
    sed -n "/^# $block begin$/,/^# $block end$/p" "$source_runtime" > "$work/$block"
    [ -s "$work/$block" ]
done
names='start_main start sing_box_init_config prepare_source_ruleset subscription_reload_seamless reload restart append_subscription_item filter_working_subscription_proxy_links refresh_subscription_cache load_subscription_proxy_links_for_section apply_subscription_exclusions_to_cached_links set_subscription_links_enabled set_subscription_sections_enabled subscription_apply_v2_restore subscription_speedtest_stop subscription_update subscription_update_json subscription_runtime_busy'
names="$names subscription_reload_pending_file"
: > "$work/pending-helpers"
if grep -Fqx 'subscription_pending_sections_json() {' "$source_runtime"; then
    for name in subscription_pending_sections_json subscription_pending_mark subscription_pending_clear; do
        grep -Fqx "$name() {" "$source_runtime" || exit 1
        sed -n "/^$name() {$/,/^}$/p" "$source_runtime" >> "$work/pending-helpers"
    done
fi
if grep -Fqx 'subscription_update_section_handler() {' "$source_runtime"; then names="$names subscription_update_section_handler"; fi
for name in $names; do
    sed -n "/^$name() {$/,/^}$/p" "$source_runtime" > "$work/$name"
    [ -s "$work/$name" ]
    grep -q "^$name() {" "$target"
done
awk -v dir="$work" -v names="$names" '
BEGIN { n=split(names,a," "); for(i=1;i<=n;i++) replace[a[i]"() {"]=a[i] }
function emit(path, line) { while ((getline line < path)>0) print line; close(path) }
$0=="# subscription_sources_v1 begin" || $0 ~ /^# subscription_isolated_probe_v[12] begin$/ || $0=="# subscription_services_v1 begin" || $0=="# subscription_service_snapshot_v1 begin" { block=1; next }
block { if($0=="# subscription_sources_v1 end" || $0 ~ /^# subscription_isolated_probe_v[12] end$/ || $0=="# subscription_services_v1 end" || $0=="# subscription_service_snapshot_v1 end") block=0; next }
$0=="get_subscription_sources)" || $0=="subscription_ping)" || $0=="subscription_config_apply)" || $0=="get_subscription_operation_status)" || $0=="subscription_services_check)" || $0=="subscription_services_confirm)" || $0=="get_subscription_services)" { skip_case=1; next }
skip_case { if($0 ~ /;;/) skip_case=0; next }
skipping { if($0=="}") skipping=0; next }
$0 ~ /^subscription_pending_(sections_json|mark|clear)\(\) \{$/ { skipping=1; next }
$0=="append_subscription_item() {" { emit(dir"/subscription_sources_v1"); emit(dir"/subscription_isolated_probe_v1"); emit(dir"/subscription_services_v1"); emit(dir"/subscription_service_snapshot_v1") }
$0 in replace { emit(dir"/"replace[$0]); if(replace[$0]=="subscription_reload_pending_file") emit(dir"/pending-helpers"); skipping=1; next }
$0=="subscription_speedtest() {" { skipping=1; next }
$0=="get_subscription_items_cached)" { print "subscription_config_apply)\n    subscription_config_apply\n    ;;\nget_subscription_operation_status)\n    get_subscription_operation_status\n    ;;\nget_subscription_sources)\n    get_subscription_sources \"$2\"\n    ;;\nsubscription_services_check)\n    subscription_services_check \"$2\" \"$3\" \"$4\"\n    ;;\nsubscription_services_confirm)\n    subscription_services_confirm \"$2\" \"$3\" \"$4\" \"$5\"\n    ;;\nget_subscription_services)\n    get_subscription_services \"$2\"\n    ;;" }
$0=="subscription_speedtest)" { print "subscription_ping)\n    subscription_ping \"$2\" \"$3\"\n    ;;" }
$0=="    subscription_update_json \"$2\"" { print "    subscription_update_json \"$2\" \"$3\""; next }
{ print }
' "$target" > "$staged"
sh -n "$staged"
[ "$(grep -c '^subscription_speedtest() {' "$staged")" -eq 1 ]
[ "$(grep -c '^get_subscription_sources)' "$staged")" -eq 1 ]
backup="${PODKOP_SOURCES_BACKUP:-${target}.before-sources}"
backup_init_once "$target" "$backup" || exit 1
chmod 755 "$staged"
mv "$staged" "$target"
upgrade_guarded_init_restart
# The full install path has to reach the engine trigger as well: a first or a
# complete upgrade must not leave the operator's "Save & Apply" event without
# a resident service that can act on it.
upgrade_engine_config_change_trigger
echo 'Installed subscription source controls and isolated diagnostics.'
