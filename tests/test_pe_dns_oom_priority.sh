#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v db_private_oom_priority >/dev/null || fail 'private OOM priority absent'
read -r parent_score < /proc/self/oom_score_adj
sleep 30 & production=$!
trap 'kill "$production" 2>/dev/null || true; rm -rf "$work"' EXIT
read -r production_score < "/proc/$production/oom_score_adj"
mkdir -p "$work/bin"
printf '#!/bin/sh\nread -r score < /proc/self/oom_score_adj\nprintf "%%s\\n" "$score"\n' > "$work/bin/sing-box"
chmod +x "$work/bin/sing-box"
# The fake native executable reports its own score after the child's exec.
for action in check run; do
    (db_private_oom_priority || exit 125; exec "$work/bin/sing-box" "$action") > "$work/$action.score"
    read -r score < "$work/$action.score"
    [ "$score" = 1000 ] || fail "$action native child is not prioritized as OOM victim"
done
if (
    # Simulate a rejected procfs write without changing a production process.
    printf() { return 1; }
    db_private_oom_priority || exit 125
    : > "$work/unsupported-executed"
); then fail 'rejected OOM policy admitted native exec'; fi
[ ! -e "$work/unsupported-executed" ] || fail 'unsupported policy executed child'
db_infrastructure_error private_oom_unavailable || fail 'policy refusal treated as DNS failure'
read -r current < /proc/self/oom_score_adj
[ "$current" = "$parent_score" ] || fail 'production parent score changed'
read -r current < "/proc/$production/oom_score_adj"
[ "$current" = "$production_score" ] || fail 'production sentinel score changed'
# Every private native entry point must opt in; checking helper alone is insufficient.
grep 'db_private_oom_priority.*sing-box check' "$repo/openwrt/podkop-dns-benchmark" >/dev/null || fail 'foreground check missing child policy'
[ "$(grep -c 'db_private_oom_priority.*sing-box run' "$repo/openwrt/podkop-dns-benchmark")" = 2 ] || fail 'front or section child missing policy'
echo 'PASS: private native check/run OOM priority, parent and production unchanged'
