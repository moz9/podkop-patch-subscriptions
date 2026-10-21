#!/bin/sh
# Bounded native diagnostics only. No service, UCI, selector or process mutation.
diag_now() {
    local uptime idle
    read -r uptime idle < "${PODKOP_DIAG_UPTIME_FILE:-/proc/uptime}" || return 1
    uptime="${uptime%%.*}"
    case "$uptime" in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$uptime"
}

diag_begin() {
    local operation="$1" seconds="$2" maximum
    case "$operation" in selection) maximum=60;; pair) maximum=12;; *) return 1;; esac
    case "$seconds" in ''|*[!0-9]*) return 1;; esac
    [ "$seconds" -gt 0 ] && [ "$seconds" -le "$maximum" ] || return 1
    DIAG_STARTED="$(diag_now)" || return 1
    DIAG_DEADLINE=$((DIAG_STARTED+seconds))
}

diag_remaining() {
    local now remaining
    [ -n "${DIAG_STARTED:-}" ] && [ -n "${DIAG_DEADLINE:-}" ] || return 1
    now="$(diag_now)" || return 1
    [ "$now" -ge "$DIAG_STARTED" ] || return 1
    remaining=$((DIAG_DEADLINE-now))
    [ "$remaining" -gt 0 ] || return 1
    printf '%s\n' "$remaining"
}

diag_request_limit() {
    local remaining
    remaining="$(diag_remaining)" || return 1
    [ "$remaining" -le 3 ] || remaining=3
    printf '%s\n' "$remaining"
}

diag_admit() {
    local estimate="$1" reserve=24576 threshold available memdoc
    case "$estimate" in ''|*[!0-9]*) return 1;; esac
    [ "$estimate" -le 8192 ] || return 1
    memdoc="${PODKOP_DIAG_MEMDOC_FILE:-/usr/bin/memdoc}"
    if [ -e "$memdoc" ]; then
        # Parse literal policy only. Never source executable watchdog code.
        threshold="$(awk '
          /^[ \t]*(export[ \t]+)?THRESHOLD=/ {
            value=$0; sub(/^[ \t]*(export[ \t]+)?THRESHOLD=/,"",value)
            sub(/[ \t]*#.*/,"",value); gsub(/[ \t\r]/,"",value)
            if (value !~ /^[0-9]+$/ || value+0>1048576) bad=1
            result=value; count++
          }
          END {if (count!=1 || bad) exit 1; print result}
        ' "$memdoc")" || return 1
        [ "$((threshold+8192))" -le "$reserve" ] || reserve=$((threshold+8192))
    fi
    available="$(awk '/^MemAvailable:/ {print $2; count++} END {if(count!=1) exit 1}' "${PODKOP_DIAG_MEMINFO_FILE:-/proc/meminfo}")" || return 1
    case "$available" in ''|*[!0-9]*) return 1;; esac
    [ "$available" -ge "$((reserve+estimate))" ]
}
