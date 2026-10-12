#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for version in 0.7.20 0.7.22; do
    runtime="$root/openwrt/runtime-$version/usr/bin/podkop"
    sed -n '/^subscription_apply_v2_reload() {/,/^}/p' "$runtime" > "$tmp/reload.sh"
    sed -n '/^subscription_cas_shared_clean() {/,/^}/p' "$runtime" >> "$tmp/reload.sh"
    (
        . "$tmp/reload.sh"
        # This reload-only fixture has no unsaved shared UCI delta.
        uci() { [ "$1" != -q ] || shift; [ "$1" = changes ] && [ "$2" = podkop ]; }
        podkop_section_enabled() { return 0; }
        podkop_section_apply() { printf applied > "$tmp/applied"; }
        subscription_apply_v2_reload || { echo 'FAIL: isolated apply attempted global reload'; exit 1; }
        test "$(cat "$tmp/applied")" = applied
        rm "$tmp/applied"
        podkop_section_apply() { return 7; }
        if subscription_apply_v2_reload; then echo 'FAIL: failed worker apply reported success'; exit 1; fi
    )
    grep -Fq 'podkop_section_preflight "$payload"' "$runtime"
    grep -Fq 'podkop_section_bootstrap "$temp_file_path"' "$runtime"
    grep -Fq 'podkop_section_api_merge "$CLASH_URL" "$auth_header"' "$runtime"
    grep -Fq 'podkop_section_logical_path' "$runtime"
done
echo 'section integration: PASS'
