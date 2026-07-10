#!/bin/sh
set -eu

target="${PODKOP_UPDATE_CENTER_TARGET:-/usr/bin/podkop}"
syntax_shell="${PODKOP_UPDATE_CENTER_SHELL:-ash}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

[ -f "$target" ] || {
    echo "ERROR: podkop runtime is missing: $target" >&2
    exit 1
}

if grep -q '^subscription_patch_update_check() {' "$target" 2>/dev/null &&
    grep -q '^get_subscription_patch_update_log() {' "$target" 2>/dev/null &&
    grep -q '^subscription_patch_update_check)$' "$target" 2>/dev/null; then
    exit 0
fi

awk '
BEGIN {
    update_wrapper = 0
    status_wrapper = 0
    helper_functions = 0
    dispatcher = 0
}

$0 == "subscription_patch_update() {" {
    print
    print "    if [ -x /usr/bin/podkop-update-manager ]; then"
    print "        /usr/bin/podkop-update-manager update_start"
    print "        return $?"
    print "    fi"
    update_wrapper = 1
    next
}

$0 == "get_subscription_patch_update_status() {" {
    print
    print "    if [ -x /usr/bin/podkop-update-manager ]; then"
    print "        /usr/bin/podkop-update-manager status"
    print "        return $?"
    print "    fi"
    status_wrapper = 1
    next
}

$0 == "subscription_action_lock_file() {" && !helper_functions {
    print "subscription_patch_update_check() {"
    print "    if [ ! -x /usr/bin/podkop-update-manager ]; then"
    print "        echo \047{\"success\":false,\"error\":\"update_manager_missing\"}\047"
    print "        return 1"
    print "    fi"
    print "    /usr/bin/podkop-update-manager check_start"
    print "}"
    print ""
    print "get_subscription_patch_update_log() {"
    print "    if [ ! -x /usr/bin/podkop-update-manager ]; then"
    print "        return 0"
    print "    fi"
    print "    /usr/bin/podkop-update-manager log"
    print "}"
    print ""
    helper_functions = 1
}

$0 == "check_proxy)" && !dispatcher {
    print "subscription_patch_update_check)"
    print "    subscription_patch_update_check"
    print "    ;;"
    print "get_subscription_patch_update_log)"
    print "    get_subscription_patch_update_log"
    print "    ;;"
    dispatcher = 1
}

{ print }

END {
    if (!update_wrapper || !status_wrapper || !helper_functions || !dispatcher) {
        exit 42
    }
}
' "$target" > "$tmp" || {
    echo "ERROR: unsupported /usr/bin/podkop layout for update center" >&2
    exit 1
}

"$syntax_shell" -n "$tmp" || {
    echo "ERROR: update center produced invalid podkop syntax" >&2
    exit 1
}

cat "$tmp" > "$target"
chmod 755 "$target"
