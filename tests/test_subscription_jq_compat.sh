#!/bin/sh
# Exercise the production filter on the installed jq, including jq 1.6 in CI.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$work/items" <<'JSON'
[{"id":"game","name":"FI [Игровой]","supported":true,"sourceIds":["active"]},
 {"id":"normal","name":"FI normal","supported":true,"sourceIds":["active"]},
 {"id":"foreign","name":"DE [Игровой]","supported":true,"sourceIds":["active"]},
 {"id":"unsupported","name":"FI [Игровой]","supported":false,"sourceIds":["active"]}]
JSON

# jq 1.7 accepts some keyword-shaped variables that jq 1.6 rejects. Guard
# argument bindings as well as executing the real function, so a local
# run on newer jq cannot silently reintroduce the older parser failure.
reserved='as|def|module|import|include|if|then|else|elif|end|and|or|reduce|foreach|try|catch|label|break'
source="$repo/openwrt/podkop-subscription-sources.sh"
sed -n '/^subscription_source_policy() {$/,/^}$/p' "$source" > "$work/canonical"
[ -s "$work/canonical" ] || fail 'canonical production policy missing'
count=0
for production in "$source" "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    [ -f "$production" ] || fail "production policy file missing: $production"
    grep -Fqx '# subscription_jq16_policy_v1' "$production" || fail "jq 1.6 capability marker missing: $production"
    sed -n '/^subscription_source_policy() {$/,/^}$/p' "$production" > "$work/policy"
    [ -s "$work/policy" ] || fail "production policy missing: $production"
    if grep -Eq -- "--(arg|argjson|slurpfile|rawfile)[[:space:]]+($reserved)([[:space:]]|$)" "$work/policy"; then
        fail "jq 1.6 reserved variable in $production"
    fi
    cmp -s "$work/canonical" "$work/policy" || fail "production policy differs from source: $production"
    # Source only this function: never execute the runtime's router entrypoint.
    . "$work/policy"
    subscription_source_policy '[]' '[]' "$work/items" auto '[]' '["@prefix:FI"]' '["@game:only"]' > "$work/result" || fail "production filter did not execute: $production"
    jq -e 'length==4 and .[0].runtimeEnabled and all(.[1,2,3]; .runtimeEnabled|not)' "$work/result" >/dev/null || fail "include/exclude intersection changed: $production"
    subscription_source_policy '[]' '[]' "$work/items" selected '["normal"]' '[]' '[]' > "$work/result" || fail "selected filter did not execute: $production"
    jq -e '.[1].runtimeEnabled and all(.[0,2,3]; .runtimeEnabled|not)' "$work/result" >/dev/null || fail "empty include or selection changed: $production"
    subscription_source_policy '["active"]' '[]' "$work/items" auto '[]' '["@prefix:FI"]' '[]' > "$work/result" || fail "disabled-source filter did not execute: $production"
    jq -e 'all(.[]; .runtimeEnabled|not)' "$work/result" >/dev/null || fail "disabled source bypassed: $production"
    count=$((count + 1))
done
printf 'PASS: jq compatibility policy executes with %s across %s production copies; reserved variables absent\n' "$(jq --version)" "$count"

# An otherwise current runtime with the old jq binding must receive the fix.
# All targets and backups are disposable files; never invoke a router runtime.
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
  for scenario in missing_marker stale_binding; do
    sed -e 's/--argjson include_patterns /--argjson include /g' \
        -e 's/\$include_patterns/\$include/g' "$runtime" > "$work/upgrade-stale"
    if [ "$scenario" = missing_marker ]; then
        sed '/^# subscription_jq16_policy_v1$/d' "$work/upgrade-stale" > "$work/upgrade-target"
    else
        cp "$work/upgrade-stale" "$work/upgrade-target"
    fi
    cp "$work/upgrade-target" "$work/upgrade-before"
    rm -f "$work/upgrade-backup"
    PODKOP_SOURCES_TARGET="$work/upgrade-target" PODKOP_SOURCES_SOURCE="$runtime" \
        PODKOP_SOURCES_BACKUP="$work/upgrade-backup" \
        sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/upgrade-log" || fail "jq 1.6 retrofit failed: $runtime"
    grep -Fqx 'Installed subscription source controls and isolated diagnostics.' "$work/upgrade-log" || fail "old jq policy was incorrectly considered installed: $runtime"
    grep -Fqx '# subscription_jq16_policy_v1' "$work/upgrade-target" || fail "retrofit omitted jq 1.6 marker: $runtime"
    cmp -s "$work/upgrade-before" "$work/upgrade-backup" || fail "retrofit failed to preserve old runtime: $runtime"
    sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$runtime" > "$work/expected-block"
    sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$work/upgrade-target" > "$work/delivered-block"
    cmp -s "$work/expected-block" "$work/delivered-block" || fail "retrofit copied stale source block: $runtime"
    sed -n '/^subscription_source_policy() {$/,/^}$/p' "$work/upgrade-target" > "$work/policy"
    . "$work/policy"
    subscription_source_policy '[]' '[]' "$work/items" auto '[]' '["@prefix:FI"]' '["@game:only"]' > "$work/result" || fail "delivered jq filter did not execute: $runtime"
    jq -e 'length==4 and .[0].runtimeEnabled and all(.[1,2,3]; .runtimeEnabled|not)' "$work/result" >/dev/null || fail "delivered filter changed behavior: $runtime"
    cp "$work/upgrade-target" "$work/upgrade-fixed"
    PODKOP_SOURCES_TARGET="$work/upgrade-target" PODKOP_SOURCES_SOURCE="$runtime" \
        PODKOP_SOURCES_BACKUP="$work/upgrade-backup" \
        sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" > "$work/upgrade-log" || fail "jq 1.6 retrofit retry failed: $runtime"
    grep -Fqx 'Subscription source controls are already installed.' "$work/upgrade-log" || fail "jq 1.6 retrofit retry was not a no-op: $runtime"
    cmp -s "$work/upgrade-fixed" "$work/upgrade-target" || fail "jq 1.6 retrofit retry changed runtime: $runtime"
    cmp -s "$work/upgrade-before" "$work/upgrade-backup" || fail "jq 1.6 retrofit retry changed backup: $runtime"
  done
done
printf 'PASS: old or stale-marker jq policy is upgraded in every runtime; corrected block executes and retry is a no-op\n'
