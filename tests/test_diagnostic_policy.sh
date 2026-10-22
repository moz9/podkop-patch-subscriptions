#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -r "$repo/openwrt/podkop-diagnostic-policy.sh" ] || fail 'bounded diagnostic policy missing'
. "$repo/openwrt/podkop-diagnostic-policy.sh"
PODKOP_DIAG_UPTIME_FILE="$work/uptime"
PODKOP_DIAG_MEMINFO_FILE="$work/meminfo"
PODKOP_DIAG_MEMDOC_FILE="$work/memdoc"
printf '100.25 0.0\n' > "$work/uptime"
printf 'THRESHOLD=20000\n' > "$work/memdoc"
printf 'MemAvailable: 36852 kB\n' > "$work/meminfo"
diag_begin selection 60 || fail 'valid start rejected'
[ "$(diag_remaining)" = 60 ] || fail 'wrong initial remaining budget'
[ "$(diag_request_limit)" = 3 ] || fail 'unbounded request'
diag_admit 8192 || fail 'smallest surveyed router cannot admit bounded native work'
cat > "$work/memdoc" <<'WATCHDOG'
if [ "$TOTAL_MEM" -gt 230000 ]; then
    THRESHOLD=20000
elif [ "$TOTAL_MEM" -gt 100000 ]; then
    THRESHOLD=3000
fi
WATCHDOG
diag_admit 8192 || fail 'valid conditional watchdog thresholds rejected'
printf 'MemAvailable: 36383 kB\n' > "$work/meminfo"
if diag_admit 8192; then fail 'new work consumed memdoc plus 8MiB reserve'; fi
[ "$DIAG_ERROR" = insufficient_memory ] || fail 'low RAM lost its actual cause'
printf 'MemAvailable: 28191 kB\n' > "$work/meminfo"
if diag_admit 0; then fail 'in-flight work continued below reserve'; fi
printf 'MemAvailable: 28192 kB\n' > "$work/meminfo"
diag_admit 0 || fail 'exact reserve rejected'
printf '158.99 0.0\n' > "$work/uptime"
[ "$(diag_request_limit)" = 2 ] || fail 'request exceeds remaining budget'
printf '160.00 0.0\n' > "$work/uptime"
if diag_request_limit; then fail 'request started after deadline'; fi
printf '90.0 0.0\n' > "$work/uptime"
if diag_remaining; then fail 'clock rollback extended operation'; fi
printf '200.0 0.0\n' > "$work/uptime"
diag_begin pair 12 || fail 'pair budget rejected'
printf '211.5 0.0\n' > "$work/uptime"
[ "$(diag_request_limit)" = 1 ] || fail 'pair request exceeds remaining second'
printf '212.0 0.0\n' > "$work/uptime"
if diag_remaining; then fail 'pair deadline ignored'; fi
if diag_begin selection 61; then fail 'unbounded selection allowed'; fi
if diag_begin pair 13; then fail 'unbounded manual pair allowed'; fi
printf 'THRESHOLD="$(touch unsafe)"\n' > "$work/memdoc"
if diag_admit 0; then fail 'unknown memory reserve treated as safe'; fi
[ "$DIAG_ERROR" = memory_policy_unreadable ] || fail 'invalid policy mislabeled as low RAM'
printf 'THRESHOLD=3000\nTHRESHOLD=$((3000+30000))\n' > "$work/memdoc"
if diag_admit 0; then fail 'dynamic threshold mixed with literal accepted'; fi
printf 'THRESHOLD=3000\nTHRESHOLD=1048577\n' > "$work/memdoc"
if diag_admit 0; then fail 'oversized branch threshold accepted'; fi
printf 'THRESHOLD=20 000\n' > "$work/memdoc"
if diag_admit 0; then fail 'split nonliteral threshold accepted'; fi
printf '  export THRESHOLD=20000   # watchdog reserve\nTHRESHOLD=3000\n' > "$work/memdoc"
printf 'MemAvailable: 28192 kB\n' > "$work/meminfo"
diag_admit 0 || fail 'literal threshold with export, indentation or comment rejected'
printf 'THRESHOLD=12000\n' > "$work/memdoc"
printf 'MemAvailable: 24575 kB\n' > "$work/meminfo"
if diag_admit 0; then fail '24MiB floor ignored'; fi
printf 'MemAvailable: 24576 kB\n' > "$work/meminfo"
diag_admit 0 || fail '24MiB reserve boundary rejected'
printf 'MemAvailable: invalid kB\n' > "$work/meminfo"
if diag_admit 0; then fail 'unknown available memory accepted'; fi
[ "$DIAG_ERROR" = memory_status_unavailable ] || fail 'unreadable RAM mislabeled as shortage'
echo 'PASS: monotonic total/pair/request deadlines and memdoc-aware resource admission'
