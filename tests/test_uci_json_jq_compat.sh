#!/bin/sh
# Exercise production serializers with the jq selected by PATH (1.6 and newer).
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$work/expected" <<'JSON'
{"main":{".type":"section","quote":"a 'single' and \"double\" quote","multiline":"first\nsecond\n","tabslash":"one\ttwo\\three","literal":"$(must_not_execute); `must_not_execute`","ordered":["second","first","first",""],"sentinel":"PODKOP_UCI_JSON_END","last":"tail"}}
JSON
# The only stub is native UCI's read-only export boundary. Feed the canonical
# shell-quoted command format into each unchanged production parser.
uci() {
    [ "$*" = "-q export $work/config/podkop" ] || return 1
    [ "${export_failure:-0}" = 0 ] || return 1
    cat "$work/export"
}
dns_reserve_saved_uci() {
    [ "$*" = "$work/saved export_json podkop" ] || return 1
    [ "${export_failure:-0}" = 0 ] || return 1
    cat "$work/export"
}
export SUBSCRIPTION_CAS_DIR="$work" SUBSCRIPTION_CAS_PACKAGE=podkop
write_export() {
    jq -r '
      "package podkop", "config section main",
      (.main | to_entries[] | select(.key!=".type") |
        if (.value|type)=="array" then .key as $key | .value[] | "list " + ($key|@sh) + " " + (@sh)
        else "option " + (.key|@sh) + " " + (.value|@sh) end)' "$work/expected" > "$work/export"
}
check_values() {
    for last in tail PODKOP_UCI_JSON_END '' final_empty_list; do
        if [ "$last" = final_empty_list ]; then
            jq '.main.last=["second","first","first",""]' "$work/expected" > "$work/next"
        else
            jq --arg last "$last" '.main.last=$last' "$work/expected" > "$work/next"
        fi
        mv "$work/next" "$work/expected"
        write_export
        "$serializer" "$work/saved" > "$work/result" || fail "serializer rejected canonical export ($last): $production"
        if [ "$serializer" = dns_reserve_saved_uci_json ]; then
            jq '.values | del(.main[".anonymous"],.main[".name"],.main[".index"])' "$work/result" > "$work/normalized"
        else
            cp "$work/result" "$work/normalized"
        fi
        jq -e --slurpfile expected "$work/expected" '.==$expected[0]' "$work/normalized" >/dev/null || fail "terminal value, quotes, newlines or list order changed ($last): $production"
    done
}
check_failures() {
    failures='export_failure eval_failure syntax_failure invalid_tag partial_triple missing_terminator extra_field orphan_option'
    if [ "$serializer" = dns_reserve_saved_uci_json ]; then
        failures="$failures anonymous_section duplicate_section metadata_option"
    fi
    for failure in $failures; do
        export_failure=0
        case "$failure" in
            orphan_option) printf '%s\n' 'option key value' > "$work/export";;
            anonymous_section) printf '%s\n' 'config section' > "$work/export";;
            duplicate_section) printf '%s\n' 'config section main' 'config section main' > "$work/export";;
            metadata_option) printf '%s\n' 'config section main' 'option .type override' > "$work/export";;
            export_failure) export_failure=1; printf '%s\n' 'config section main' > "$work/export";;
            eval_failure) printf '%s\n' 'config section main' 'option key value' 'false' > "$work/export";;
            syntax_failure) printf '%s\n' 'config section main' "option key 'unterminated" > "$work/export";;
            invalid_tag) printf '%s\n' "printf 'bad\\000key\\000value\\000'" > "$work/export";;
            partial_triple) printf '%s\n' "printf '$config_tag\\000section\\000main\\000$option_tag\\000broken\\000'" > "$work/export";;
            missing_terminator) printf '%s\n' "printf '$config_tag\\000section\\000main\\000$option_tag\\000key\\000value'" > "$work/export";;
            extra_field) printf '%s\n' "printf '$config_tag\\000section\\000main\\000\\000'" > "$work/export";;
        esac
        if "$serializer" "$work/saved" > "$work/result" 2> "$work/error"; then
            fail "$failure accepted: $production"
        fi
        [ ! -s "$work/result" ] || fail "$failure emitted partial JSON: $production"
    done
    export_failure=0
    for empty in empty_export package_only; do
      : > "$work/export"
      [ "$empty" = empty_export ] || printf '%s\n' 'package podkop' > "$work/export"
    "$serializer" "$work/saved" > "$work/result" || fail "empty package rejected: $production"
    if [ "$serializer" = dns_reserve_saved_uci_json ]; then
        jq -e '.=={values:{}}' "$work/result" >/dev/null || fail "empty saved package changed: $production"
    else
        jq -e '.=={}' "$work/result" >/dev/null || fail "empty CAS package changed: $production"
    fi
    done
}
count=0
for production in "$repo/openwrt/podkop-subscription-sources.sh" "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    grep -Fqx '# subscription_jq16_uci_v1' "$production" || fail "UCI framing capability marker missing: $production"
    serializer=subscription_cas_config_json
    config_tag=c; option_tag=o
    sed -n '/^subscription_cas_config_json() ($/,/^)/p' "$production" > "$work/serializer"
    [ -s "$work/serializer" ] || fail "CAS serializer missing: $production"
    . "$work/serializer"
    check_values
    check_failures
    count=$((count + 1))
done
if [ -f "$repo/openwrt/podkop-dns-apply" ] && grep -q '^dns_reserve_saved_uci_json() (' "$repo/openwrt/podkop-dns-apply"; then
    production="$repo/openwrt/podkop-dns-apply"
    serializer=dns_reserve_saved_uci_json
    config_tag=config; option_tag=option
    sed -n '/^dns_reserve_saved_uci_json() ($/,/^)/p' "$production" > "$work/serializer"
    . "$work/serializer"
    check_values
    check_failures
    count=$((count + 1))
fi
printf 'PASS: UCI JSON serializers preserve terminal values, quoting and ordered lists; malformed frames and replay failures are rejected with %s (%s production copies)\n' "$(jq --version)" "$count"

# Reproduce an otherwise-current runtime's pre-fix serializer, including a
# stale capability marker, then exercise the real retrofit and no-op retry.
cat > "$work/old-serializer" <<'OLD'
subscription_cas_config_json() (
    local data
    data="$(uci -q export "$SUBSCRIPTION_CAS_DIR/config/$SUBSCRIPTION_CAS_PACKAGE")" || exit 1
    package() { :; }
    config() { printf 'c\000%s\000%s\000' "$1" "$2"; }
    option() { printf 'o\000%s\000%s\000' "$1" "$2"; }
    list() { printf 'l\000%s\000%s\000' "$1" "$2"; }
    eval "$data" | jq -Rsc '
      split("\u0000") | .[:-1] | . as $a
      | reduce range(0; length; 3) as $i ({rows:{},section:null};
          if $a[$i]=="c" then .section=$a[$i+2] | .rows[.section]={".type":$a[$i+1]}
          elif $a[$i]=="o" then .rows[.section][$a[$i+1]]=$a[$i+2]
          elif $a[$i]=="l" then .rows[.section][$a[$i+1]]=((.rows[.section][$a[$i+1]]//[])+[$a[$i+2]])
          else error("invalid_export") end) | .rows'
)
OLD
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    for scenario in missing_marker stale_marker; do
        awk -v old="$work/old-serializer" -v scenario="$scenario" '
          $0=="# subscription_jq16_uci_v1" && scenario=="missing_marker" { next }
          $0=="subscription_cas_config_json() (" {
              while ((getline line < old)>0) print line; close(old); skip=1; next
          }
          skip { if ($0==")") skip=0; next }
          { print }
        ' "$runtime" > "$work/upgrade-target"
        cp "$work/upgrade-target" "$work/upgrade-before"
        rm -f "$work/upgrade-backup"
        PODKOP_SOURCES_TARGET="$work/upgrade-target" PODKOP_SOURCES_SOURCE="$runtime" \
            PODKOP_SOURCES_BACKUP="$work/upgrade-backup" \
            sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/upgrade-log" || fail "UCI framing retrofit failed ($scenario): $runtime"
        grep -Fqx 'Installed subscription source controls and isolated diagnostics.' "$work/upgrade-log" || fail "old serializer incorrectly considered installed ($scenario): $runtime"
        grep -Fqx '# subscription_jq16_uci_v1' "$work/upgrade-target" || fail "retrofit omitted UCI framing marker: $runtime"
        cmp -s "$work/upgrade-before" "$work/upgrade-backup" || fail "retrofit lost original runtime: $runtime"
        sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$runtime" > "$work/expected-block"
        sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$work/upgrade-target" > "$work/delivered-block"
        cmp -s "$work/expected-block" "$work/delivered-block" || fail "retrofit copied stale source block: $runtime"
        production="$work/upgrade-target"; serializer=subscription_cas_config_json
        sed -n '/^subscription_cas_config_json() ($/,/^)/p' "$production" > "$work/serializer"
        . "$work/serializer"
        check_values
        cp "$work/upgrade-target" "$work/upgrade-fixed"
        PODKOP_SOURCES_TARGET="$work/upgrade-target" PODKOP_SOURCES_SOURCE="$runtime" \
            PODKOP_SOURCES_BACKUP="$work/upgrade-backup" \
            sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/upgrade-log" || fail "UCI framing retrofit retry failed: $runtime"
        grep -Fqx 'Subscription source controls are already installed.' "$work/upgrade-log" || fail "UCI framing retry was not a no-op: $runtime"
        cmp -s "$work/upgrade-fixed" "$work/upgrade-target" || fail "UCI framing retry changed runtime: $runtime"
        cmp -s "$work/upgrade-before" "$work/upgrade-backup" || fail "UCI framing retry changed backup: $runtime"
    done
done
printf 'PASS: UCI framing fix upgrades every old or stale-marker runtime and retries without changes\n'
