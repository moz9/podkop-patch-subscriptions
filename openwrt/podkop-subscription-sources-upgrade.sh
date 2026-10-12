#!/bin/sh
set -eu
target="${PODKOP_SOURCES_TARGET:-/usr/bin/podkop}"
source_runtime="${PODKOP_SOURCES_SOURCE:?canonical runtime is required}"
work="$(mktemp -d /tmp/podkop-sources-upgrade.XXXXXX)"
staged="${target}.sources.$$"
trap 'rm -rf "$work"; rm -f "$staged"' EXIT INT TERM HUP
[ -f "$target" ] && [ -f "$source_runtime" ]
sh -n "$source_runtime"
upgrade_guarded_init_restart() {
    local init_target init_staged init_backup
    init_target="${PODKOP_SOURCES_INIT_TARGET:-}"
    if [ -z "$init_target" ] && [ "$target" = /usr/bin/podkop ]; then init_target=/etc/init.d/podkop; fi
    [ -n "$init_target" ] || return 0
    [ -f "$init_target" ] && [ ! -L "$init_target" ] || return 1
    if grep -Fqx '# subscription_safe_init_restart_v1' "$init_target"; then
        sed -n '/^restart() {$/,/^}$/p' "$init_target" | grep -Fq '/usr/bin/podkop restart' || return 1
        return 0
    fi
    # Never replace a foreign custom restart implementation by assumption.
    ! grep -Eq '^[[:space:]]*restart[[:space:]]*\(\)' "$init_target" || return 1
    grep -Fq 'USE_PROCD=1' "$init_target" && grep -Fq '/usr/bin/podkop start' "$init_target" &&
        grep -Fq '/usr/bin/podkop stop' "$init_target" || return 1
    init_staged="$init_target.sources-restart.$$"
    [ ! -e "$init_staged" ] && [ ! -L "$init_staged" ] || return 1
    cp -p "$init_target" "$init_staged" || return 1
    printf '\n%s\n' '# subscription_safe_init_restart_v1' 'restart() {' '    /usr/bin/podkop restart' '}' >> "$init_staged"
    if ! sh -n "$init_staged"; then rm -f "$init_staged"; return 1; fi
    init_backup="${init_target}.before-sources-restart"
    if [ ! -e "$init_backup" ]; then cp -p "$init_target" "$init_backup" || { rm -f "$init_staged"; return 1; }; fi
    mv "$init_staged" "$init_target"
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
        [ -e "$backup" ] || cp -p "$target" "$backup"
        chmod 755 "$staged"
        mv "$staged" "$target"
    fi
    grep -Fqx 'subscription_services_restart_prepare() {' "$target" || exit 1
    upgrade_guarded_init_restart
    echo 'Installed only guarded admitted-runtime restart lifecycle.'
    exit 0
fi
cas_help_present() {
    sed -n '/^show_help() {$/,/^}$/p' "$1" | awk '
    $0=="    get_subscription_snapshot" { snapshot=1 }
    $0=="    set_subscription_link_enabled <section> <id> <enabled> <revision>" { single=1 }
    $0=="    set_subscription_links_enabled <section> <revision> <id> <enabled> [...]" { bulk=1 }
    $0=="    set_subscription_sections_enabled <json>" { json=1 }
    index($0,"JSON payload requires sections[].expectedRevision for every section") { revision=1 }
    END { exit !(snapshot && single && bulk && json && revision) }
    '
}

extract_cas_help() {
    sed -n '/^show_help() {$/,/^}$/p' "$1" | awk '
    /^    (get_subscription_snapshot|set_subscription_(link|links|sections)_enabled)([[:space:]]|$)/ { selected=1; print; next }
    selected && /^    [^ ]/ { selected=0 }
    selected && /^ +/ { print }
    '
}

cas_help_present "$source_runtime"
extract_cas_help "$source_runtime" > "$work/cas.help"
if cas_help_present "$target" &&
    grep -Fqx '# subscription_cas_v1 begin' "$target" &&
    grep -Fqx '# subscription_cas_v1 end' "$target" &&
    grep -Fqx 'get_subscription_snapshot() (' "$target" &&
    grep -Fqx 'get_subscription_snapshot)' "$target" &&
    grep -Fqx '    set_subscription_link_enabled "$2" "$3" "$4" "$5"' "$target" &&
    sed -n '/^set_subscription_sections_enabled() {/,/^}/p' "$target" | grep -F 'expectedRevision' >/dev/null &&
    sed -n '/^set_subscription_links_enabled() {/,/^}/p' "$target" | grep -F 'expectedRevision' >/dev/null &&
    sed -n '/^set_subscription_link_enabled() {/,/^}/p' "$target" | grep -Fq '"${4:-}"' &&
    grep -Fqx '# subscription_choices_and_busy_v1' "$target" &&
    grep -Fqx '# subscription_resource_admission_v1' "$target" &&
    sed -n '/^download_subscription_once() {/,/^}/p' "$target" | grep -Fq 'download_status' &&
    sed -n '/^refresh_subscription_cache() {/,/^}/p' "$target" | grep -Fq 'subscription_resource_cache' &&
    sed -n '/^subscription_reconcile_choices() {/,/^}/p' "$target" | grep -Fq 'def row_index($rows;$kind):' &&
    grep -Fq "# single_runtime_status_v1" "$target" &&
    grep -Fqx '# subscription_light_probe_v1' "$target" &&
    grep -Fqx '# subscription_selection_v1' "$target" &&
    grep -Fqx '# subscription_tag_filters_v1' "$target" &&
    grep -Fqx '# subscription_tag_glob_portable_v1' "$target" &&
    grep -Fqx '# subscription_jq16_policy_v1' "$target" &&
    grep -Fqx '# subscription_jq16_uci_v1' "$target" &&
    sed -n '/^subscription_cas_config_json() ($/,/^)/p' "$target" | grep -F "printf '%s' 'PODKOP_UCI_JSON_END'" >/dev/null &&
    sed -n '/^subscription_source_policy() {/,/^}/p' "$target" | grep -F -- '--argjson include_patterns ' >/dev/null &&
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
    exit 0
fi
for block in subscription_sources_v1 subscription_isolated_probe_v1 subscription_services_v1 subscription_service_snapshot_v1 subscription_apply_v2; do
    sed -n "/^# $block begin$/,/^# $block end$/p" "$source_runtime" > "$work/$block"
    [ -s "$work/$block" ]
done
grep -Fqx '# subscription_cas_v1 begin' "$work/subscription_sources_v1"
grep -Fqx '# subscription_cas_v1 end' "$work/subscription_sources_v1"
grep -Fqx 'get_subscription_snapshot() (' "$work/subscription_sources_v1"
grep -Fq 'expectedRevision' "$work/subscription_apply_v2"
names='extract_subscription_proxy_links download_subscription_once download_subscription_to_file normalize_subscription_file start_main start sing_box_init_config prepare_source_ruleset subscription_reload_seamless reload restart append_subscription_item filter_working_subscription_proxy_links refresh_subscription_cache load_subscription_proxy_links_for_section apply_subscription_exclusions_to_cached_links set_subscription_link_enabled set_subscription_links_enabled subscription_speedtest_stop subscription_update subscription_update_json subscription_runtime_busy'
for name in $names; do
    sed -n "/^$name() {$/,/^}$/p" "$source_runtime" > "$work/$name"
    [ -s "$work/$name" ]
    grep -q "^$name() {" "$target"
done
awk -v dir="$work" -v names="$names" '
BEGIN { n=split(names,a," "); for(i=1;i<=n;i++) replace[a[i]"() {"]=a[i] }
function emit(path, line) { while ((getline line < path)>0) print line; close(path) }
$0=="# subscription_sources_v1 begin" || $0 ~ /^# subscription_isolated_probe_v[12] begin$/ || $0=="# subscription_services_v1 begin" || $0=="# subscription_service_snapshot_v1 begin" || $0=="# subscription_apply_v2 begin" { block=1; next }
block { if($0=="# subscription_sources_v1 end" || $0 ~ /^# subscription_isolated_probe_v[12] end$/ || $0=="# subscription_services_v1 end" || $0=="# subscription_service_snapshot_v1 end" || $0=="# subscription_apply_v2 end") block=0; next }
$0=="get_subscription_snapshot)" || $0=="get_subscription_sources)" || $0=="subscription_ping)" || $0=="get_subscription_operation_status)" || $0=="subscription_services_check)" || $0=="subscription_services_confirm)" || $0=="get_subscription_services)" { skip_case=1; next }
skip_case { if($0 ~ /;;/) skip_case=0; next }
skipping { if($0=="}") skipping=0; next }
$0=="append_subscription_item() {" { emit(dir"/subscription_sources_v1"); emit(dir"/subscription_isolated_probe_v1"); emit(dir"/subscription_services_v1"); emit(dir"/subscription_service_snapshot_v1"); emit(dir"/subscription_apply_v2") }
$0 in replace { emit(dir"/"replace[$0]); skipping=1; next }
$0=="subscription_speedtest() {" { skipping=1; next }
$0=="get_subscription_items_cached)" { print "get_subscription_snapshot)\n    get_subscription_snapshot\n    ;;\nget_subscription_operation_status)\n    get_subscription_operation_status\n    ;;\nget_subscription_sources)\n    get_subscription_sources \"$2\"\n    ;;\nsubscription_services_check)\n    subscription_services_check \"$2\" \"$3\" \"$4\"\n    ;;\nsubscription_services_confirm)\n    subscription_services_confirm \"$2\" \"$3\" \"$4\" \"$5\"\n    ;;\nget_subscription_services)\n    get_subscription_services \"$2\"\n    ;;" }
$0=="    set_subscription_link_enabled \"$2\" \"$3\" \"$4\"" { print "    set_subscription_link_enabled \"$2\" \"$3\" \"$4\" \"$5\""; next }
$0=="subscription_speedtest)" { print "subscription_ping)\n    subscription_ping \"$2\" \"$3\"\n    ;;" }
$0=="    subscription_update_json \"$2\"" { print "    subscription_update_json \"$2\" \"$3\""; next }
{ print }
' "$target" > "$work/runtime.body"
awk -v cas_help="$work/cas.help" '
$0=="show_help() {" { in_help=1 }
in_help && /^    (get_subscription_snapshot|set_subscription_(link|links|sections)_enabled)([[:space:]]|$)/ {
    if(!help_inserted) {
        while((getline help_line < cas_help)>0) print help_line
        close(cas_help); help_inserted=1
    }
    skip_help_description=1; next
}
in_help && skip_help_description && /^     +/ { next }
in_help { skip_help_description=0; if($0=="}")in_help=0 }
{ print }
END { if(!help_inserted) exit 42 }
' "$work/runtime.body" > "$staged"
cas_help_present "$staged"
sh -n "$staged"
[ "$(grep -c '^subscription_speedtest() {' "$staged")" -eq 1 ]
[ "$(grep -c '^get_subscription_sources)' "$staged")" -eq 1 ]
[ "$(grep -Fxc '# subscription_cas_v1 begin' "$staged")" -eq 1 ]
[ "$(grep -Fxc '# subscription_apply_v2 begin' "$staged")" -eq 1 ]
[ "$(grep -Fxc 'get_subscription_snapshot)' "$staged")" -eq 1 ]
sed -n '/^set_subscription_sections_enabled() {/,/^}/p' "$staged" | grep -F 'expectedRevision' >/dev/null
sed -n '/^set_subscription_links_enabled() {/,/^}/p' "$staged" | grep -F 'expectedRevision' >/dev/null 
# Historical canonical runtimes may intentionally lack newer unrelated
# capability markers. Exact staged equality is still a safe no-op.
if cmp -s "$staged" "$target"; then
    upgrade_guarded_init_restart
    echo 'Subscription source controls are already installed.'
    exit 0
fi
backup="${PODKOP_SOURCES_BACKUP:-${target}.before-sources}"
[ -e "$backup" ] || cp -p "$target" "$backup"
chmod 755 "$staged"
mv "$staged" "$target"
upgrade_guarded_init_restart
echo 'Installed subscription source controls and isolated diagnostics.'
