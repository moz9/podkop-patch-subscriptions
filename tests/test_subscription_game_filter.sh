#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
printf '%s\n' '[{"id":"normal","name":"🇫🇮 Финляндия","supported":true,"sourceIds":["active"]},{"id":"game","name":"🇫🇮 Финляндия [🎮 Игровой]","supported":true,"sourceIds":["active"]},{"id":"other","name":"US [Игровой]","supported":true,"sourceIds":["active"]},{"id":"emoji","name":"FI Hysteria2 🎮","supported":true,"sourceIds":["active"]},{"id":"broken","name":"FI [Игровой]","supported":false,"sourceIds":["active"]}]' > "$work/items"
for version in $(jq -r '.supportedPodkopVersions[]' "$repo/openwrt/update-manifest.json"); do
    runtime="$repo/openwrt/runtime-$version/usr/bin/podkop"
    [ -f "$runtime" ] || continue
    sed -n '/^# subscription_sources_v1 begin$/,/^# subscription_sources_v1 end$/p' "$runtime" > "$work/backend"
    . "$work/backend"
    policy() { subscription_source_policy '[]' '[]' "$work/items" auto '[]' "$1" "$2"; }
    policy '["@prefix:FI"]' '["@game:only"]' | jq -e '.[1].runtimeEnabled and all(.[0,2,3,4]; .runtimeEnabled|not)' >/dev/null || fail 'gaming-only must intersect country and support policy'
    policy '["@prefix:FI"]' '["@game:exclude"]' | jq -e '.[0].runtimeEnabled and .[3].runtimeEnabled and all(.[1,2,4]; .runtimeEnabled|not)' >/dev/null || fail 'non-gaming must not infer protocol or emoji'
    policy '["@prefix:FI"]' '[]' | jq -e 'all(.[0,1,3]; .runtimeEnabled)' >/dev/null || fail 'All must retain existing country behavior'
    policy '[]' '["@game:only","@game:exclude"]' | jq -e 'all(.[]; .runtimeEnabled|not)' >/dev/null || fail 'conflicting game rules must fail closed'
    policy '["@prefix:FI"]' '["@game:only","@prefix:FI"]' | jq -e 'all(.[]; .runtimeEnabled|not)' >/dev/null || fail 'country exclusion must win'
    subscription_source_policy '["active"]' '[]' "$work/items" auto '[]' '[]' '["@game:only"]' | jq -e 'all(.[]; .runtimeEnabled|not)' >/dev/null || fail 'disabled sources must remain excluded'
    subscription_source_policy '[]' '[]' "$work/items" selected '["normal"]' '[]' '["@game:only"]' | jq -e 'all(.[]; .runtimeEnabled|not)' >/dev/null || fail 'manual selection must remain an intersection'
    subscription_source_policy '[]' '[]' "$work/items" auto '[]' '[]' '["@game:only"]' '{"required":["gemini"],"results":[{"id":"game","services":{"gemini":{"state":"fail"}}}]}' | jq -e 'all(.[]; .runtimeEnabled|not)' >/dev/null || fail 'required services must retain priority'
    sed '/^# subscription_game_filter_v1$/d' "$runtime" > "$work/old"
    PODKOP_SOURCES_TARGET="$work/old" PODKOP_SOURCES_SOURCE="$runtime" sh "$repo/openwrt/podkop-subscription-sources-upgrade.sh" >/dev/null
    grep -Fqx '# subscription_game_filter_v1' "$work/old" || fail 'existing installations must receive game policy'
done
echo 'PASS: game policy intersects countries, sources, selection and services in every runtime; upgrade delivers it'
