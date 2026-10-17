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

has_wrapper() {
    sed -n "/^$1() {/,/^}/p" "$target" | grep -Fq "/usr/bin/podkop-update-manager $2"
}
update=0; status=0; check=0; log=0; check_case=0; log_case=0
has_wrapper subscription_patch_update update_start || update=1
has_wrapper get_subscription_patch_update_status status || status=1
grep -q '^subscription_patch_update_check() {' "$target" || check=1
grep -q '^get_subscription_patch_update_log() {' "$target" || log=1
grep -q '^subscription_patch_update_check)$' "$target" || check_case=1
grep -q '^get_subscription_patch_update_log)$' "$target" || log_case=1
if [ "$update$status$check$log$check_case$log_case" = 000000 ]; then
    exit 0
fi

awk -v need_update="$update" -v need_status="$status" -v need_check="$check" -v need_log="$log" \
    -v need_check_case="$check_case" -v need_log_case="$log_case" '
BEGIN {
    update_wrapper = !need_update
    status_wrapper = !need_status
    helper_functions = !(need_check || need_log)
    dispatcher = !(need_check_case || need_log_case)
}

$0 == "subscription_patch_update() {" && need_update {
    print
    print "    if [ -x /usr/bin/podkop-update-manager ]; then"
    print "        /usr/bin/podkop-update-manager update_start"
    print "        return $?"
    print "    fi"
    update_wrapper = 1
    next
}

$0 == "get_subscription_patch_update_status() {" && need_status {
    print
    print "    if [ -x /usr/bin/podkop-update-manager ]; then"
    print "        /usr/bin/podkop-update-manager status"
    print "        return $?"
    print "    fi"
    status_wrapper = 1
    next
}

$0 == "subscription_action_lock_file() {" && !helper_functions {
    if (need_check) {
    print "subscription_patch_update_check() {"
    print "    if [ ! -x /usr/bin/podkop-update-manager ]; then"
    print "        echo \047{\"success\":false,\"error\":\"update_manager_missing\"}\047"
    print "        return 1"
    print "    fi"
    print "    /usr/bin/podkop-update-manager check_start"
    print "}"
    print ""
    }
    if (need_log) {
    print "get_subscription_patch_update_log() {"
    print "    if [ ! -x /usr/bin/podkop-update-manager ]; then"
    print "        return 0"
    print "    fi"
    print "    /usr/bin/podkop-update-manager log"
    print "}"
    print ""
    }
    helper_functions = 1
}

$0 == "check_proxy)" && !dispatcher {
    if (need_check_case) {
    print "subscription_patch_update_check)"
    print "    subscription_patch_update_check"
    print "    ;;"
    }
    if (need_log_case) {
    print "get_subscription_patch_update_log)"
    print "    get_subscription_patch_update_log"
    print "    ;;"
    }
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
