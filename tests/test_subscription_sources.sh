#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
module="$repo/openwrt/podkop-subscription-sources.sh"
[ -f "$module" ] || { echo 'FAIL: subscription source policy is missing'; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
. "$module"
cat > "$tmp/items" <<'EOF'
[
 {"id":"a","supported":true,"enabled":true,"sourceIds":["one"]},
 {"id":"b","supported":true,"enabled":false,"sourceIds":["two"]},
 {"id":"c","supported":true,"enabled":true,"sourceIds":["one","two"]},
 {"id":"d","supported":false,"enabled":false,"sourceIds":["one"]}
]
EOF
subscription_source_policy '["one"]' '["b"]' "$tmp/items" > "$tmp/result"
jq -e '.[0].enabled == true and .[0].runtimeEnabled == false and .[1].enabled == false and .[2].runtimeEnabled == true and .[3].runtimeEnabled == false' "$tmp/result" >/dev/null
subscription_source_policy '["one","two"]' '["b"]' "$tmp/result" > "$tmp/all-off"
jq -e 'all(.[]; .runtimeEnabled == false) and .[0].enabled == true' "$tmp/all-off" >/dev/null
subscription_source_policy '[]' '["b"]' "$tmp/all-off" > "$tmp/restored"
jq -e '.[0].runtimeEnabled == true and .[1].enabled == false and .[2].runtimeEnabled == true' "$tmp/restored" >/dev/null
# Newly downloaded configs inherit the subscription policy, not an old per-link snapshot.
printf '%s\n' '[{"id":"new","supported":true,"enabled":true,"sourceIds":["one"]}]' > "$tmp/new"
subscription_source_policy '["one"]' '[]' "$tmp/new" | jq -e '.[0].runtimeEnabled == false and .[0].enabled == true' >/dev/null
# Unknown provenance must fail closed when a source is disabled.
printf '%s\n' '[{"id":"old","supported":true,"enabled":true}]' > "$tmp/old"
subscription_source_policy '["one"]' '[]' "$tmp/old" | jq -e '.[0].runtimeEnabled == false' >/dev/null
echo 'PASS: source disable, shared configs, preferences, refresh and fail-closed policy'
