#!/bin/sh
# Offline only: transform fixture files; never run a router runtime or service.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d /tmp/podkop-cas-delivery-XXXXXX)"
trap 'rm -rf "$work"' EXIT INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
blocks='subscription_sources_v1 subscription_isolated_probe_v1 subscription_services_v1 subscription_service_snapshot_v1 subscription_apply_v2'
wrappers='set_subscription_link_enabled set_subscription_links_enabled'

assert_graph() {
    local target="$1" source="$2" block name
    sh -n "$target" || fail 'delivered runtime syntax'
    sed -n '/^show_help() {$/,/^}$/p' "$target" > "$work/help"
    grep -Fqx '    get_subscription_snapshot' "$work/help" || fail 'snapshot absent from help'
    grep -Fqx '    set_subscription_link_enabled <section> <id> <enabled> <revision>' "$work/help" || fail 'single-toggle help drops revision'
    grep -Fqx '    set_subscription_links_enabled <section> <revision> <id> <enabled> [...]' "$work/help" || fail 'bulk help argument order is wrong'
    grep -Fqx '    set_subscription_sections_enabled <json>' "$work/help" || fail 'JSON help missing'
    grep -Fq 'sections[].expectedRevision' "$work/help" || fail 'JSON help omits required section revisions' 
    for block in $blocks; do
        [ "$(grep -Fxc "# $block begin" "$target")" -eq 1 ] || fail "duplicate/missing $block"
        sed -n "/^# $block begin$/,/^# $block end$/p" "$target" > "$work/got"
        sed -n "/^# $block begin$/,/^# $block end$/p" "$source" > "$work/want"
        cmp -s "$work/got" "$work/want" || fail "stale $block dependency"
    done
    for name in $wrappers; do
        [ "$(grep -Fxc "$name() {" "$target")" -eq 1 ] || fail "duplicate/missing $name wrapper"
        sed -n "/^$name() {$/,/^}$/p" "$target" > "$work/got"
        sed -n "/^$name() {$/,/^}$/p" "$source" > "$work/want"
        cmp -s "$work/got" "$work/want" || fail "stale $name wrapper"
    done
    [ "$(grep -Fxc '# subscription_cas_v1 begin' "$target")" -eq 1 ] || fail 'missing CAS marker'
    [ "$(grep -Fxc 'get_subscription_snapshot() (' "$target")" -eq 1 ] || fail 'missing snapshot function'
    [ "$(grep -Fxc 'get_subscription_snapshot)' "$target")" -eq 1 ] || fail 'missing snapshot dispatcher'
    sed -n '/^get_subscription_snapshot)$/,/;;/p' "$target" | grep -Fqx '    get_subscription_snapshot' || fail 'snapshot dispatcher must take no arguments'
    grep -Fqx '    set_subscription_link_enabled "$2" "$3" "$4" "$5"' "$target" || fail 'single dispatcher drops revision'
    sed -n '/^set_subscription_sections_enabled() {$/,/^}$/p' "$target" | grep -F 'expectedRevision' >/dev/null || fail 'transaction drops revision'
}

make_target() {
    local source="$1" target="$2" variant="$3" version="$4"
    awk -v variant="$variant" -v version="$version" '
    NR==1 { print "#!/bin/sh"; print "if [ \"${1:-}\" = show_version ]; then echo \"" version "\"; exit 0; fi"; next }
    $0=="show_help() {" { in_help=1 }
    in_help && $0=="}" { in_help=0 }
    variant=="stale_help" && in_help { sub(/ <section>.*$/,"" ); sub(/ <json>$/,"" ); gsub(/expectedRevision/,"oldRevision") }
    variant=="missing_helpers" && /^# subscription_(sources_v1|isolated_probe_v[12]|services_v1|service_snapshot_v1|apply_v2) begin$/ { skip_block=1; next }
    skip_block { if($0 ~ /^# subscription_(sources_v1|isolated_probe_v[12]|services_v1|service_snapshot_v1|apply_v2) end$/)skip_block=0; next }
    variant=="stale_wrappers" && /^set_subscription_links?_enabled\(\) \{$/ { print; print "    return 1"; print "}"; skip_fn=1; next }
    skip_fn { if($0=="}")skip_fn=0; next }
    variant=="old_dispatcher" && $0=="    set_subscription_link_enabled \"$2\" \"$3\" \"$4\" \"$5\"" { print "    set_subscription_link_enabled \"$2\" \"$3\" \"$4\""; next }
    variant=="pre_cas" && $0=="# subscription_cas_v1 begin" { skip=1; next }
    skip { if($0=="# subscription_cas_v1 end")skip=0; next }
    (variant=="pre_cas" || variant=="no_dispatcher") && $0=="get_subscription_snapshot)" { skip_case=1; next }
    skip_case { if($0 ~ /;;/)skip_case=0; next }
    variant=="pre_cas" || variant=="stale_revision" {
        gsub(/expectedRevision/,"preCasExpectedRevision")
        gsub(/    set_subscription_link_enabled \"\$2\" \"\$3\" \"\$4\" \"\$5\"/,"    set_subscription_link_enabled \"$2\" \"$3\" \"$4\"")
    }
    { print }
    ' "$source" > "$target"
    chmod +x "$target"
}

for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    version=${runtime#*/runtime-}; version=${version%%/*}
    source="$work/source-$version"
    cp "$runtime" "$source"
    for entry in sources apply-v2; do
        for variant in pre_cas missing_helpers stale_revision stale_wrappers no_dispatcher old_dispatcher stale_help; do
            target="$work/$version-$entry-$variant"
            make_target "$source" "$target" "$variant" "$version"
            cp "$target" "$work/before"
            if [ "$entry" = sources ]; then
                PODKOP_SOURCES_TARGET="$target" PODKOP_SOURCES_SOURCE="$source" PODKOP_SOURCES_BACKUP="$target.backup" \
                    sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/result" || fail "$version sources $variant upgrade"
            else
                PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$target" PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$source" PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$target.backup" \
                    sh "$repo/openwrt/podkop-subscription-apply-v2-upgrade.sh" > "$work/result" || fail "$version apply-v2 $variant upgrade"
            fi
            ! grep -Fq 'already installed' "$work/result" || fail "$entry $variant falsely skipped"
            cmp -s "$target.backup" "$work/before" || fail "$entry original backup differs"
            assert_graph "$target" "$source"
            cp "$target" "$work/after"
            if [ "$entry" = sources ]; then
                PODKOP_SOURCES_TARGET="$target" PODKOP_SOURCES_SOURCE="$source" PODKOP_SOURCES_BACKUP="$target.unexpected" \
                    sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/result" || fail "$entry no-op"
            else
                PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$target" PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$source" PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$target.unexpected" \
                    sh "$repo/openwrt/podkop-subscription-apply-v2-upgrade.sh" > "$work/result" || fail "$entry no-op"
            fi
            grep -Fq 'already installed' "$work/result" || fail "$version $entry no-op not detected"
            [ ! -e "$target.unexpected" ] || fail "$entry no-op created backup"
            cmp -s "$target" "$work/after" || fail "$entry no-op rewrote runtime"
        done
        # An outdated canonical source is rejected before touching the target.
        make_target "$source" "$work/stale-source" pre_cas "$version"
        make_target "$source" "$work/reject-target" pre_cas "$version"
        cp "$work/reject-target" "$work/reject-before"
        if [ "$entry" = sources ]; then
            if PODKOP_SOURCES_TARGET="$work/reject-target" PODKOP_SOURCES_SOURCE="$work/stale-source" \
                PODKOP_SOURCES_BACKUP="$work/reject-backup" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/reject.log" 2>&1; then fail 'sources accepted stale canonical CAS'; fi
        else
            if PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$work/reject-target" PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$work/stale-source" \
                PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$work/reject-backup" sh "$repo/openwrt/podkop-subscription-apply-v2-upgrade.sh" > "$work/reject.log" 2>&1; then fail 'apply-v2 accepted stale canonical CAS'; fi
        fi
        cmp -s "$work/reject-target" "$work/reject-before" || fail "$entry rejection touched target"
        [ ! -e "$work/reject-backup" ] || fail "$entry rejection made backup"
    done
    echo "PASS: $version CAS upgrades preserve complete helper graph, wrappers, dispatcher, backup and idempotence"
done
cmp -s "$repo/i" "$repo/openwrt/install.sh" || fail 'installer mirrors differ'
for installer in "$repo/i" "$repo/openwrt/install.sh"; do
    sed -n '/^has_latest_subscription_backend() {$/,/^}$/p' "$installer" > "$work/latest"
    grep -Fq "# subscription_cas_v1 begin" "$work/latest" && grep -Fq 'get_subscription_snapshot)' "$work/latest" &&
        grep -Fq 'expectedRevision' "$work/latest" || fail 'installer no-op gate misses CAS capability'
    grep -Fq "! grep -Fqx '# subscription_cas_v1 begin'" "$installer" || fail 'installer upgrade gate misses CAS marker'
    grep -Fq "! grep -Fqx 'get_subscription_snapshot)'" "$installer" || fail 'installer upgrade gate misses snapshot dispatcher'
    grep -Fqx '    set_subscription_link_enabled "$2" "$3" "$4" "$5"' "$installer" || fail 'installer fallback drops revision'
    grep -Fqx '    set_subscription_link_enabled <section> <id> <enabled> <revision>' "$installer" || fail 'fallback single help missing'
    grep -Fqx '    set_subscription_links_enabled <section> <revision> <id> <enabled> [...]' "$installer" || fail 'fallback bulk help missing'
    grep -Fq 'sections[].expectedRevision' "$installer" || fail 'fallback JSON revision help missing' 
done
echo 'PASS: installer capability gates and fallback dispatcher require CAS'
