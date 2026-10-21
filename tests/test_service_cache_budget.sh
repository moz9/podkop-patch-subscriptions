#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-checks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_SERVICE_CACHE_DIR="$work/cache"
subscription_services_context() { if [ "$1" = other_route ]; then echo route-b; else echo route-a; fi; }
validate_subscription_section_name() { :; }
validate_subscription_link_id() { [ "${#1}" = 32 ]; }
subscription_services_mark_pending() { :; }
date() { if [ "$*" = +%s ]; then echo 100000; else command date "$@"; fi; }
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
subscription_services_store main "$id" '{"gemini":{"state":"pass","network":"pass"}}'
subscription_services_read peer | jq -e '.[0].services.gemini.state=="pass"' >/dev/null || fail 'compatible sections repeat the same node check'
subscription_services_read other_route | jq -e '.==[]' >/dev/null || fail 'different route reused evidence'
[ ! -e "$work/cache/main.json" ] || fail 'insertion rewrites whole section JSON'
subscription_services_store main "$id" '{"chatgpt":{"state":"unknown","reason":"challenge_required"}}'
subscription_services_read main | jq -e '.[0].services.gemini.state=="pass" and .[0].services.chatgpt.expiresAt==100900' >/dev/null || fail 'subset update lost another observation'
# A cache insertion may replace only its fixed slot, never a frozen admission.
mkdir -p "$work/snapshot"; echo frozen > "$work/snapshot/snapshot.json"
n=0
while [ "$n" -lt 270 ]; do
    id="$(printf '%032x' "$n")"
    subscription_services_store main "$id" '{"gemini":{"state":"pass","network":"pass"}}' || fail 'bounded cache insert'
    n=$((n+1))
done
bytes="$(du -sk "$work/cache/observations-v2" | awk '{print $1}')"
[ "$bytes" -le 1024 ] || fail "cache allocation exceeds 1 MiB: $bytes KiB"
[ "$(cat "$work/snapshot/snapshot.json")" = frozen ] || fail 'eviction touched admission'
# Oversized/corrupt observations must not make the cache unbounded.
huge="$(jq -cn '{gemini:{state:"pass",reason:("x"*5000)}}')"
if subscription_services_store main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$huge"; then fail 'oversized row accepted'; fi
subscription_services_read main | jq -e 'type=="array" and length<=240' >/dev/null || fail 'cache read not bounded'
echo 'PASS: compatible-node reuse, route isolation, incremental subset updates and global 1 MiB cache'

