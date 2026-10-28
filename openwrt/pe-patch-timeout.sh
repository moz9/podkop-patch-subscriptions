# Portable timeout: many OpenWrt builds do not include the timeout applet.
bounded() {
 seconds="$1"; shift
 "$@" & task_pid=$!
 ( sleep "$seconds"; kill "$task_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 & guard_pid=$!
 wait "$task_pid"; task_rc=$?
 kill "$guard_pid" 2>/dev/null
 wait "$guard_pid" 2>/dev/null
 return "$task_rc"
}
