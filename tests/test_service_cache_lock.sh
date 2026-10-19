#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-checks.sh"
export PODKOP_SERVICE_CACHE_DIR="$work/cache"
fail() { echo "FAIL: $*" >&2; exit 1; }
(
 subscription_services_cache_lock || exit 1
 [ "$(cat "$SERVICE_CACHE_LOCK/owner")" = "$$" ] || exit 1
 (subscription_services_cache_lock) && exit 1
 :
) || fail 'cache lock owner invalid or live owner stolen'
mkdir "$work/cache/observations-v2/write.lock"
printf '2147483647\n' > "$work/cache/observations-v2/write.lock/owner"
(subscription_services_cache_lock) || fail 'dead writer prevents recovery'
[ ! -e "$work/cache/observations-v2/write.lock" ] || fail 'owned lock not released'
echo 'PASS: cache writer identity, live lock refusal and dead writer recovery'
