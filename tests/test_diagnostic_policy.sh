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
printf 'MemAvailable: 36383 kB\n' > "$work/meminfo"
if diag_admit 8192; then fail 'new work consumed memdoc plus 8MiB reserve'; fi
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
printf 'THRESHOLD=12000\n' > "$work/memdoc"
printf 'MemAvailable: 24575 kB\n' > "$work/meminfo"
if diag_admit 0; then fail '24MiB floor ignored'; fi
printf 'MemAvailable: 24576 kB\n' > "$work/meminfo"
diag_admit 0 || fail '24MiB reserve boundary rejected'
printf 'MemAvailable: invalid kB\n' > "$work/meminfo"
if diag_admit 0; then fail 'unknown available memory accepted'; fi
echo 'PASS: monotonic total/pair/request deadlines and memdoc-aware resource admission'
