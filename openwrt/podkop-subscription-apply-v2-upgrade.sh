#!/bin/sh
set -eu

target="${PODKOP_SUBSCRIPTION_APPLY_V2_TARGET:-/usr/bin/podkop}"
source_runtime="${PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE:-}"
patch_version="${PODKOP_PATCH_VERSION:-main}"
raw_base="${PODKOP_PATCH_RAW_BASE:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$patch_version/openwrt}"
tmp_dir="$(mktemp -d /tmp/podkop-subscription-apply-v2-upgrade.XXXXXX)"
staged_target="${target}.subscription-apply-v2.$$"

cleanup() {
    rm -rf "$tmp_dir"
    rm -f "$staged_target"
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'Subscription apply v2 upgrade failed: %s\n' "$1" >&2
    exit 1
}

service_guards_present() {
    local file="$1"
    grep -Fqx '# subscription_jq16_service_guards_v1' "$file" &&
        sed -n '/^subscription_services_confirm() ($/,/^)/p' "$file" | grep -F 'jq -se --arg service "$service"' | grep -F 'length==1 and (.[0]|type)=="object" and .[0].services[$service].network=="pass"' >/dev/null &&
        sed -n '/^subscription_services_classify() {/,/^}/p' "$file" | grep -F 'jq -se' | grep -F 'length==1 and (.[0] | type=="object" and (.models|type=="array" and length>0 and all(.[]; type=="object" and ((.slug // .id)|type=="string" and length>0))))' >/dev/null &&
        sed -n '/^subscription_services_validate() {/,/^}/p' "$file" | grep -F 'jq -se' | grep -F 'length==1 and (.[0] | type=="array" and length<=' >/dev/null &&
        sed -n '/^subscription_services_read() {/,/^}/p' "$file" | grep -F 'jq -cs --arg context' >/dev/null &&
        sed -n '/^subscription_services_read() {/,/^}/p' "$file" | grep -F 'if length==1 and (.[0]|type)=="object" and (.[0].results|type)=="array" then .[0] else {} end' >/dev/null &&
        sed -n '/^subscription_services_policy() {/,/^}/p' "$file" | grep -F 'jq -cs --argjson required "$required"' | grep -F 'if length==1 and (.[0]|type)=="array" then {required:$required,results:.[0]} else error("invalid_service_results") end' >/dev/null &&
        sed -n '/^subscription_source_policy() {/,/^}/p' "$file" | grep -F '[ "$#" -lt 8 ] || services="$8"' >/dev/null &&
        sed -n '/^subscription_source_policy() {/,/^}/p' "$file" | grep -F '"$services" | jq -cs ' >/dev/null &&
        sed -n '/^subscription_source_policy() {/,/^}/p' "$file" | grep -F 'if length==1 and (.[0]|type)=="object" and (.[0].required|type)=="array" and (.[0].results|type)=="array" then .[0] else error("invalid_service_policy") end' >/dev/null
}

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

cas_capabilities_present() {
    local file="$1"
    cas_help_present "$file" &&
        service_guards_present "$file" &&
        grep -Fqx '# subscription_apply_v2 begin' "$file" &&
        grep -Fqx '# subscription_apply_v2 end' "$file" &&
        grep -Fqx '# subscription_cas_v1 begin' "$file" &&
        grep -Fqx '# subscription_cas_v1 end' "$file" &&
        grep -Fqx 'get_subscription_snapshot() (' "$file" &&
        grep -Fqx 'get_subscription_snapshot)' "$file" &&
        grep -Fqx 'set_subscription_sections_enabled)' "$file" &&
        grep -Fqx 'subscription_action_lock_dir() {' "$file" &&
        grep -Fqx 'subscription_services_context() {' "$file" &&
        grep -Fqx '# subscription_service_snapshot_v1 end' "$file" &&
        sed -n '/^set_subscription_sections_enabled() {/,/^}/p' "$file" | grep -F 'expectedRevision' >/dev/null &&
        sed -n '/^set_subscription_links_enabled() {/,/^}/p' "$file" | grep -F 'expectedRevision' >/dev/null &&
        sed -n '/^set_subscription_link_enabled() {/,/^}/p' "$file" | grep -Fq '"${4:-}"' &&
        grep -Fqx '    set_subscription_link_enabled "$2" "$3" "$4" "$5"' "$file"
}

download_source_runtime() {
    local source_version url output
    # 0.7.19/0.7.21 use the supported 0.7.20 helper source. Native versions
    # retain their own policy semantics instead of silently importing older ones.
    case "$version" in 0.7.19|0.7.21) source_version=0.7.20;; *) source_version="$version";; esac
    url="$raw_base/runtime-$source_version/usr/bin/podkop"
    output="$tmp_dir/source-runtime"
    if command -v curl > /dev/null 2>&1 &&
        curl -fsSL --connect-timeout 10 -m 45 -o "$output" "$url"; then
        source_runtime="$output"; return 0
    fi
    if command -v wget > /dev/null 2>&1 &&
        wget -T 45 -O "$output" "$url"; then
        source_runtime="$output"; return 0
    fi
    return 1
}

[ -f "$target" ] && [ ! -L "$target" ] || fail "runtime not found or is a symlink at $target"
grep -q '^set_subscription_links_enabled() {' "$target" ||
    fail 'subscription selection backend is not installed'

version="$($target show_version 2> /dev/null | sed 's/^v//' | head -n 1 || true)"
case "$version" in
0.7.19 | 0.7.20 | 0.7.21 | 0.7.22) ;;
*) fail "unsupported Podkop version: ${version:-unknown}" ;;
esac

if cas_capabilities_present "$target"; then
    printf '%s\n' 'Subscription apply v2 with CAS is already installed.'
    exit 0
fi

if [ -z "$source_runtime" ]; then
    download_source_runtime || fail 'unable to download canonical v2 runtime source'
fi
[ -f "$source_runtime" ] || fail "canonical runtime source not found at $source_runtime"
sh -n "$source_runtime" || fail 'canonical runtime source has invalid shell syntax'
cas_capabilities_present "$source_runtime" || fail 'canonical runtime lacks the complete CAS contract'
extract_cas_help "$source_runtime" > "$tmp_dir/cas.help"

# Carry the dependency closure with the transaction, including services used by
# snapshots/revisions. This standalone upgrader must not depend on a previous
# sources upgrade having run, and must not retain stale wrapper definitions.
blocks='subscription_sources_v1 subscription_isolated_probe_v1 subscription_services_v1 subscription_service_snapshot_v1 subscription_apply_v2'
: > "$tmp_dir/helpers.block"
for block in $blocks; do
    sed -n "/^# $block begin$/,/^# $block end$/p" "$source_runtime" > "$tmp_dir/$block"
    [ "$(grep -Fxc "# $block begin" "$tmp_dir/$block")" -eq 1 ] &&
        [ "$(grep -Fxc "# $block end" "$tmp_dir/$block")" -eq 1 ] || fail "canonical $block is missing or duplicated"
    cat "$tmp_dir/$block" >> "$tmp_dir/helpers.block"
    printf '\n' >> "$tmp_dir/helpers.block"
done
for name in set_subscription_link_enabled set_subscription_links_enabled; do
    sed -n "/^$name() {$/,/^}$/p" "$source_runtime" > "$tmp_dir/$name"
    [ -s "$tmp_dir/$name" ] || fail "canonical $name wrapper is missing"
    cat "$tmp_dir/$name" >> "$tmp_dir/helpers.block"
    printf '\n' >> "$tmp_dir/helpers.block"
done
optional_names=''
for name in subscription_reload_pending_file subscription_pending_sections_json subscription_pending_mark subscription_pending_clear; do
    if grep -Fqx "$name() {" "$source_runtime"; then
        sed -n "/^$name() {$/,/^}$/p" "$source_runtime" >> "$tmp_dir/helpers.block"
        printf '\n' >> "$tmp_dir/helpers.block"
        optional_names="$optional_names $name"
    fi
done
sed -n '/^subscription_action_lock_file() {$/,/^# sing-box funcs$/p' "$source_runtime" |
    sed '$d' > "$tmp_dir/lock.block"
[ -s "$tmp_dir/lock.block" ] || fail 'canonical lock block is empty'

awk -v block="$tmp_dir/lock.block" '
BEGIN { replacing=0; replaced=0 }
$0=="subscription_action_lock_file() {" {
    while((getline line < block)>0) print line
    close(block); replacing=1; replaced++; next
}
replacing && $0=="# sing-box funcs" { replacing=0; print; next }
replacing { next }
{ print }
END { if(replaced!=1 || replacing) exit 42 }
' "$target" > "$tmp_dir/runtime.lock" || fail 'unable to replace subscription action lock'

awk -v helpers="$tmp_dir/helpers.block" -v optional_names="$optional_names" '
BEGIN { inserted=0; n=split(optional_names,a," "); for(i=1;i<=n;i++) optional[a[i]"() {"]=1 }
/^# subscription_(sources_v1|isolated_probe_v[12]|services_v1|service_snapshot_v1|apply_v2) begin$/ { block=1; next }
block { if($0 ~ /^# subscription_(sources_v1|isolated_probe_v[12]|services_v1|service_snapshot_v1|apply_v2) end$/) block=0; next }
/^set_subscription_links?_enabled\(\) \{$/ || $0=="subscription_speedtest() {" || $0 in optional { fn=1; next }
fn { if($0=="}") fn=0; next }
!inserted && $0=="subscription_update_section_handler() {" {
    while((getline line < helpers)>0) print line
    close(helpers); inserted++; print ""
}
{ print }
END { if(inserted!=1 || block || fn) exit 42 }
' "$tmp_dir/runtime.lock" > "$tmp_dir/runtime.helpers" || fail 'unable to replace CAS helper dependency blocks'

awk -v cas_help="$tmp_dir/cas.help" '
function dispatch() {
    print "get_subscription_snapshot)\n    get_subscription_snapshot\n    ;;"
    print "set_subscription_link_enabled)\n    set_subscription_link_enabled \"$2\" \"$3\" \"$4\" \"$5\"\n    ;;"
    print "set_subscription_links_enabled)\n    shift\n    set_subscription_links_enabled \"$@\"\n    ;;"
    print "set_subscription_sections_enabled)\n    set_subscription_sections_enabled \"$2\"\n    ;;"
}
BEGIN { help=0; cases=0 }
/^get_subscription_snapshot\)$/ || /^set_subscription_(link|links|sections)_enabled\)$/ {
    if(!cases) { dispatch(); cases=1 }
    skip_case=1; next
}
skip_case { if($0 ~ /^[[:space:]]*;;[[:space:]]*$/) skip_case=0; next }
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
END { if(!cases || skip_case || !help_inserted) exit 42 }
' "$tmp_dir/runtime.helpers" > "$tmp_dir/runtime.final" || fail 'unable to install CAS dispatcher entries'

cas_capabilities_present "$tmp_dir/runtime.final" || fail 'complete CAS capability verification failed'
for block in $blocks; do
    [ "$(grep -Fxc "# $block begin" "$tmp_dir/runtime.final")" -eq 1 ] || fail "duplicate $block block"
done
for entry in get_subscription_snapshot set_subscription_link_enabled set_subscription_links_enabled set_subscription_sections_enabled; do
    [ "$(grep -Fxc "$entry)" "$tmp_dir/runtime.final")" -eq 1 ] || fail "duplicate $entry dispatcher"
done
sh -n "$tmp_dir/runtime.final" || fail 'upgraded runtime has invalid shell syntax'

backup="${PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP:-/root/podkop-subscription-apply-v2-backup-$(date +%Y%m%d-%H%M%S)-$$}"
cp -p "$target" "$backup" || fail 'unable to back up current runtime'
cp "$tmp_dir/runtime.final" "$staged_target" || fail 'unable to stage upgraded runtime'
chmod 755 "$staged_target" || fail 'unable to set runtime permissions'
mv "$staged_target" "$target" || fail 'unable to atomically install upgraded runtime'
printf 'Installed subscription apply v2 with CAS. Backup: %s\n' "$backup"
