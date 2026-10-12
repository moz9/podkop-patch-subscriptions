#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
export WATCH_PIDS="$work/watch-pids"
. "$repo/openwrt/podkop-dns-benchmark"
db_prepare
mkdir "$work/bin"
real_sleep="$(command -v sleep)"
cat > "$work/bin/sleep" <<EOF
#!/bin/sh
printf '%s\\n' "\$\$" >> "\$WATCH_PIDS"
exec "$real_sleep" "\$@"
EOF
chmod +x "$work/bin/sleep"
PATH="$work/bin:$PATH"; export PATH
# Several fast commands must not leave one sleep per query behind.
for iteration in 1 2 3 4; do
    db_native_command sh -c '"$1" 0.1' -- "$real_sleep"
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then echo "FAIL: native watchdog sleep $pid survived command return" >&2; exit 1; fi
    done < "$WATCH_PIDS"
done
[ "$(wc -l < "$WATCH_PIDS")" -ge 4 ] || { echo 'FAIL: watcher sleeps not exercised' >&2; exit 1; }
# Signal the actual command wrapper (the transport records its direct parent),
# then require both the transport and watchdog's sleep to be gone.
export NATIVE_PARENT="$work/native-parent" NATIVE_CHILD="$work/native-child"
db_native_command sh -c 'echo "$PPID" > "$NATIVE_PARENT"; echo "$$" > "$NATIVE_CHILD"; exec "$1" 20' -- "$real_sleep" & runner=$!
attempts=0
while [ ! -s "$NATIVE_PARENT" ] || [ "$(wc -l < "$WATCH_PIDS")" -lt 5 ]; do
    "$real_sleep" 0.02; attempts=$((attempts+1)); [ "$attempts" -lt 100 ] || { echo 'FAIL: signalled watcher did not start' >&2; exit 1; }
done
kill -TERM "$(cat "$NATIVE_PARENT")"
if wait "$runner"; then echo 'FAIL: signalled native command returned success' >&2; exit 1; fi
for pid in $(cat "$WATCH_PIDS" "$NATIVE_CHILD"); do
    if kill -0 "$pid" 2>/dev/null; then echo "FAIL: native descendant $pid survived signal" >&2; exit 1; fi
done
echo 'PASS: native command completion and signal reap transport/watchdog sleeps without accumulation'
