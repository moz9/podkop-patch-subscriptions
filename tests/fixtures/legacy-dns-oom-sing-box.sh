#!/bin/sh
read -r score < /proc/self/oom_score_adj || exit 1
printf '%s|%s|%s|%s\n' "$1" "$score" "${GOGC:-unset}" "${GOMEMLIMIT:-unset}" >> "$OOM_TRACE"
if [ "$1" = run ]; then exec sleep 30; fi
