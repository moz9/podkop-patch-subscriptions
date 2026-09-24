#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-subscription-sources.sh"
command -v subscription_reconcile_choices >/dev/null || { echo 'FAIL: no stable choice reconciliation'; exit 1; }
printf '[{"id":"old","name":"Node","protocol":"vless","transport":"tcp","connectionKey":"same","sourceIds":["s"]}]' > "$work/old"
printf '[{"id":"new","name":"Renamed","protocol":"vless","transport":"tcp","connectionKey":"same","sourceIds":["s"],"supported":true}]' > "$work/new"
subscription_reconcile_choices "$work/old" "$work/new" > "$work/result"
subscription_source_policy '[]' '["old"]' "$work/result" | jq -e '.[0].selectionId=="old" and .[0].enabled==false' >/dev/null
# Endpoint or credential rotation with the same unique label retains its choice.
jq '.[0].name="Node" | .[0].connectionKey="rotated"' "$work/new" > "$work/rotated"
subscription_reconcile_choices "$work/old" "$work/rotated" | jq -e '.[0].selectionId=="old"' >/dev/null
# Do not guess between identical labels or different subscriptions.
jq '. + [.[0] + {id:"other"}]' "$work/rotated" > "$work/duplicate"
subscription_reconcile_choices "$work/old" "$work/duplicate" | jq -e 'all(.[]; .selectionId==.id and .selectionNew)' >/dev/null
jq '.[0].sourceIds=["another"]' "$work/new" > "$work/foreign"
subscription_reconcile_choices "$work/old" "$work/foreign" | jq -e '.[0].selectionId=="new"' >/dev/null
# Identity survives several refreshes, not only the first one.
subscription_reconcile_choices "$work/result" "$work/new" | jq -e '.[0].selectionId=="old"' >/dev/null
echo 'PASS: choices survive safe matches; duplicate labels and unrelated sources are not guessed'
