#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    (
        . "$repo/openwrt/podkop-service-snapshot.sh"
        log() { :; }
        subscription_sing_box_pid() { :; }
        required=0
        config_foreach() { "$1" main; }
        validate_subscription_urltest_section() { return 0; }
        subscription_required_services_json() { [ "$required" = 0 ] && echo '[]' || echo '["chatgpt"]'; }
        subscription_services_preflight() { return 0; }
        subscription_services_continuity_context_ready() { return 0; }
        subscription_services_snapshot_continuity_prepare() { return 1; }
        subscription_services_snapshot_dir() { echo "$tmp/admission"; }
        mkdir -p "$tmp/admission"
        printf '{"version":1,"config":"%064d","sections":[],"rules":[]}\n' 0 > "$tmp/admission/snapshot.json"
        eval "$(sed -n '/^restart() {$/,/^}$/p' "$runtime")"
        eval "$(sed -n '/^reload() {$/,/^}$/p' "$runtime")"
        # Exercise the real admission branch, stopping before network work.
        eval "$(sed -n '/^start_main() {$/,/^    check_requirements$/p' "$runtime" | sed '$d'); return 0; }"
        stop_main() { echo stopped >> "$tmp/events"; }
        stop() { stop_main; }
        start() { start_main; }
        restart || fail 'empty stale receipt blocked unfiltered restart after stopping proxy'
        [ "$(cat "$tmp/events")" = stopped ] || fail 'unfiltered restart did not start normally'
        rm "$tmp/events"
        reload || fail 'empty stale receipt blocked unfiltered reload'
        rm "$tmp/events"
        required=1
        restart && fail 'new required filter accepted an empty receipt' || :
        [ ! -e "$tmp/events" ] || fail 'invalid required receipt was checked after stop'
        required=0
        printf '{"version":1,"sections":[{"section":"main","admittedIds":["old"]}]}\n' > "$tmp/admission/snapshot.json"
        restart && fail 'stale nonempty receipt accepted' || :
        [ ! -e "$tmp/events" ] || fail 'stale nonempty receipt reached stop'
        echo broken > "$tmp/admission/snapshot.json"
        reload && fail 'malformed receipt accepted' || :
        [ ! -e "$tmp/events" ] || fail 'malformed receipt reached stop'
        rm "$tmp/admission/snapshot.json"
    ) || exit 1
done
echo 'PASS: empty unfiltered receipts are not mandatory evidence; invalid admissions fail before stop'
