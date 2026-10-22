#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
set -- "$repo"/openwrt/runtime-*/usr/bin/podkop
if [ "$(jq -r 'if .routerdeskPatch.mode == "files-only" then "prepared" else (.releaseStatus // "released") end' "$repo/openwrt/update-manifest.json")" = prepared ]; then
    set -- "$repo/openwrt/runtime-0.7.24/usr/bin/podkop"
fi
for runtime do
    (
        . "$repo/openwrt/podkop-service-snapshot.sh"
        log() { :; }
        required=1; continuity=0; fresh=1
        config_foreach() { "$1" main; }
        validate_subscription_urltest_section() { return 0; }
        subscription_required_services_json() { [ "$required" = 0 ] && echo '[]' || echo '["gemini"]'; }
        subscription_services_preflight() { [ "$fresh" = 1 ]; }
        subscription_services_snapshot_continuity_prepare() { [ "$continuity" = 1 ]; }
        stop() { echo stop >> "$tmp/events"; }
        stop_main() { stop; }
        start() { echo "start:${PODKOP_SERVICE_RESTART_CONTINUITY:-0}" >> "$tmp/events"; }
        start_main() { start; }
        eval "$(sed -n '/^restart() {$/,/^}$/p' "$runtime")"
        eval "$(sed -n '/^reload() {$/,/^}$/p' "$runtime")"
        restart && fail 'mismatched admission was stopped despite fresh evidence' || :
        [ ! -e "$tmp/events" ] || fail 'mismatched admission reached stop'
        continuity=1; fresh=0
        restart || fail 'expired evidence blocked exact admitted restart'
        [ "$(cat "$tmp/events")" = "$(printf 'stop\nstart:1')" ] || fail 'restart did not carry exact-runtime reuse'
        rm "$tmp/events"
        reload || fail 'expired evidence blocked exact admitted reload'
        [ "$(cat "$tmp/events")" = "$(printf 'stop\nstart:1')" ] || fail 'reload did not carry exact-runtime reuse'
        rm "$tmp/events"
        PODKOP_SUBSCRIPTION_APPLY_NOW=1
        restart && fail 'explicit apply bypassed fresh evidence' || :
        [ ! -e "$tmp/events" ] || fail 'invalid explicit apply reached stop'
        fresh=1
        restart || fail 'fresh explicit apply rejected'
        [ "$(cat "$tmp/events")" = "$(printf 'stop\nstart:0')" ] || fail 'explicit apply incorrectly reused old graph'
        rm "$tmp/events"; unset PODKOP_SUBSCRIPTION_APPLY_NOW
        required=0
        restart || fail 'default-off restart rejected'
        [ "$(cat "$tmp/events")" = "$(printf 'stop\nstart:0')" ] || fail 'default-off restart changed behavior'
        rm "$tmp/events"
        # Exercise the real start_main/sing_box_init_config reuse branch too:
        # fresh evidence must not turn a restart into candidate generation.
        check_requirements() { :; }
        process_validate_service() { :; }
        br_netfilter_disable() { :; }
        route_table_rule_mark() { :; }
        create_nft_rules() { :; }
        restore_cached_community_subnet_lists() { :; }
        community_subnet_lists_enabled() { return 1; }
        sing_box_configure_service() { :; }
        remove_cron_job() { :; }
        add_cron_job() { :; }
        add_subscription_cron_job() { :; }
        podkop_section_enabled() { return 1; }
        migration() { fail 'admitted restart ran migration'; }
        subscription_services_snapshot_save() { fail 'admitted restart refreshed admission'; }
        sing_box_configure_log() { fail 'admitted restart generated new candidate'; }
        daemon_start() { echo started > "$tmp/daemon-started"; }
        sleep() { :; }
        PODKOP_SERVICE_RESTART_CONTINUITY=1
        PODKOP_SKIP_LIST_UPDATE=1
        TMP_SING_BOX_FOLDER="$tmp/sb"; TMP_RULESET_FOLDER="$tmp/rules"
        eval "$(sed -n '/^sing_box_init_config() {$/,/^}$/p' "$runtime")"
        eval "$(sed -n '/^start_main() {$/,/^}$/p' "$runtime" | sed 's|/usr/sbin/ntpd .*|:|;s|/etc/init.d/sing-box start|daemon_start|')"
        start_main || fail 'real start_main failed admitted restart'
        [ -e "$tmp/daemon-started" ] || fail 'admitted runtime did not start'
        rm "$tmp/daemon-started"
        unset PODKOP_SERVICE_RESTART_CONTINUITY
        subscription_services_snapshot_dir() { printf '%s/admission\n' "$tmp"; }
        mkdir "$tmp/admission"
        printf '{}\n' > "$tmp/admission/snapshot.json"
        route_table_rule_mark() { echo changed > "$tmp/network-changed"; }
        start_main || fail 'ordinary cold start did not prefer existing admission'
        [ -e "$tmp/daemon-started" ] || fail 'ordinary admitted cold start did not activate'
        rm "$tmp/daemon-started" "$tmp/network-changed"
        continuity=0
        start_main && fail 'mismatched cold start accepted despite fresh evidence' || :
        [ ! -e "$tmp/daemon-started" ] && [ ! -e "$tmp/network-changed" ] || fail 'mismatched cold start touched network or daemon'
        continuity=1
        podkop_section_enabled() { return 0; }
        podkop_section_context_matches() { return 1; }
        podkop_section_root() { printf '%s/section-context' "$tmp"; }
        mkdir -p "$tmp/section-context"
        rm -f "$tmp/context-hash-read"
        printf 'v2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$tmp/section-context/context.sha256"
        podkop_section_context_hash() {
            : > "$tmp/context-hash-read"
            printf 'v2:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
        }
        start_main 2> "$tmp/context-refusal.stderr" && fail 'stale traffic context permitted network reconfiguration' || :
        [ ! -s "$tmp/context-refusal.stderr" ] || fail 'context refusal was caused by an incomplete fixture'
        [ -f "$tmp/context-hash-read" ] || fail 'saved and desired traffic contexts were not compared'
        [ ! -e "$tmp/daemon-started" ] && [ ! -e "$tmp/network-changed" ] || fail 'traffic-context refusal touched network or daemon'
        rm "$tmp/admission/snapshot.json"; rmdir "$tmp/admission"
    ) || exit 1
    cp "$runtime" "$tmp/runtime"
    printf '%s\n' '#!/bin/sh /etc/rc.common' 'USE_PROCD=1' 'start_service() { /usr/bin/podkop start; }' 'stop_service() { /usr/bin/podkop stop; }' 'reload_service() { /usr/bin/podkop reload; }' > "$tmp/init"
    cp "$tmp/init" "$tmp/original-init"
    # Reproduce deployed pre-guard lifecycle while preserving all other bytes.
    awk '
      /^subscription_services_restart_prepare\(\) \{$/ {skip=1; next}
      skip {if($0=="}") skip=0; next}
      /# subscription_safe_restart_v1:/ || $0=="    local PODKOP_SERVICE_RESTART_CONTINUITY=0" {next}
      $0=="    if [ \"$PODKOP_SERVICE_REUSE_ADMITTED_CONFIG\" = 1 ]; then" {branch=1; next}
      branch {if($0=="    elif ! subscription_services_preflight; then") {print "    if ! subscription_services_preflight; then"; branch=0}; next}
      {gsub(/PODKOP_SERVICE_REUSE_ADMITTED_CONFIG="\$\{PODKOP_SERVICE_RESTART_CONTINUITY:-0\}"/,"PODKOP_SERVICE_REUSE_ADMITTED_CONFIG=0");
       if($0=="    subscription_services_restart_prepare || return 1") $0="    subscription_services_preflight || return 1"; print}
    ' "$runtime" > "$tmp/runtime"
    cp "$tmp/runtime" "$tmp/old-runtime"
    PODKOP_SOURCES_SAFE_RESTART_ONLY=1 PODKOP_SOURCES_TARGET="$tmp/runtime" PODKOP_SOURCES_SOURCE="$runtime" PODKOP_SOURCES_INIT_TARGET="$tmp/init" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    for function in start_main reload restart subscription_services_restart_prepare; do
        sed -n "/^$function() {$/,/^}$/p" "$runtime" > "$tmp/expected-function"
        sed -n "/^$function() {$/,/^}$/p" "$tmp/runtime" > "$tmp/actual-function"
        cmp "$tmp/expected-function" "$tmp/actual-function" || fail 'restricted lifecycle retrofit drifted'
    done
    for source in old-runtime runtime; do
        awk '/^(start_main|reload|restart|subscription_services_restart_prepare)\(\) \{$/ {skip=1; next} skip {if($0=="}") skip=0; next} {print}' "$tmp/$source" > "$tmp/$source.untouched"
    done
    cmp "$tmp/old-runtime.untouched" "$tmp/runtime.untouched" || fail 'restricted retrofit touched unrelated runtime code'
    cp "$tmp/runtime" "$tmp/once-runtime"
    PODKOP_SOURCES_SAFE_RESTART_ONLY=1 PODKOP_SOURCES_TARGET="$tmp/runtime" PODKOP_SOURCES_SOURCE="$runtime" PODKOP_SOURCES_INIT_TARGET="$tmp/init" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    cmp "$tmp/runtime" "$tmp/once-runtime" || fail 'restricted retrofit not idempotent'
    PODKOP_SOURCES_TARGET="$tmp/runtime" PODKOP_SOURCES_SOURCE="$runtime" PODKOP_SOURCES_INIT_TARGET="$tmp/init" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    (
        stop() { echo stop >> "$tmp/init-events"; }
        start() { echo start >> "$tmp/init-events"; }
        restart() { stop; start; }
        runtime_dispatch() { [ "$1" = restart ] || fail 'unexpected init dispatch'; return 7; }
        eval "$(sed 's|/usr/bin/podkop|runtime_dispatch|g' "$tmp/init")"
        code=0; restart || code=$?
        [ "$code" = 7 ] || fail 'init restart did not propagate native guard failure'
        [ ! -e "$tmp/init-events" ] || fail 'rc.common restart stopped before native guard'
    ) || exit 1
    cp "$tmp/init" "$tmp/init-once"
    PODKOP_SOURCES_TARGET="$tmp/runtime" PODKOP_SOURCES_SOURCE="$runtime" PODKOP_SOURCES_INIT_TARGET="$tmp/init" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    cmp "$tmp/init" "$tmp/init-once" || fail 'init restart upgrade not idempotent'
    cmp "$tmp/init.before-sources-restart" "$tmp/original-init" || fail 'original init backup missing'
    rm "$tmp/init.before-sources-restart"
done
echo 'PASS: guarded init restart, exact admitted continuity, stale mismatch refusal, explicit apply and default-off separation'
