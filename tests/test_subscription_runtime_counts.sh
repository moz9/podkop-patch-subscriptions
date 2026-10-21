#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT HUP INT TERM
ROOT="$work" FRONTEND="$work/active.json"
sed -n '/^status() ($/,/^)/p' "$repo/openwrt/podkop-single-runtime" > "$work/status.sh"
. "$work/status.sh"
main_ready() { [ "${unavailable:-0}" = 0 ] && printf '123 456\n'; }
workers_stopped() { return 0; }
printf '%s\n' '{"section":"main","sections":[{"section":"main"},{"section":"GEOBLOCK"}]}' > "$ROOT/metadata.json"
cat > "$FRONTEND" <<'JSON'
{"outbounds":[{"tag":"direct-out","type":"direct"},{"tag":"main-out","type":"selector","outbounds":["main-urltest-out","a","b","c"]},{"tag":"main-urltest-out","type":"urltest","outbounds":["a","b","c"]},{"tag":"a","type":"vless"},{"tag":"b","type":"trojan"},{"tag":"c","type":"hysteria2"},{"tag":"GEOBLOCK-out","type":"selector","outbounds":["d","e"]},{"tag":"d","type":"vless"},{"tag":"e","type":"vless"}]}
JSON
before="$(sha256sum "$FRONTEND" "$ROOT/metadata.json")"
status | jq -e '.ready and [.sections[].activeNodeCount]==[3,2]' >/dev/null
[ "$before" = "$(sha256sum "$FRONTEND" "$ROOT/metadata.json")" ]
jq '.outbounds += [{"tag":"manual","type":"vless"}] | .outbounds|=map(if .tag=="main-out" then .outbounds+=["manual"] else . end)' "$FRONTEND" > "$work/next"; mv "$work/next" "$FRONTEND"
status | jq -e '.sections[0].activeNodeCount==4' >/dev/null
unavailable=1
status | jq -e '(.ready|not) and all(.sections[];.activeNodeCount==null)' >/dev/null
unavailable=0
jq '.outbounds|=map(if .tag=="main-urltest-out" then .outbounds=[] elif .tag=="main-out" then .outbounds=["main-urltest-out"] else . end)' "$FRONTEND" > "$work/next"; mv "$work/next" "$FRONTEND"
status | jq -e '.sections[0].activeNodeCount==0 and .sections[1].activeNodeCount==2' >/dev/null
jq '.outbounds|=map(select(.tag!="GEOBLOCK-out"))' "$FRONTEND" > "$work/next"; mv "$work/next" "$FRONTEND"
status | jq -e '.sections[1].activeNodeCount==null' >/dev/null
jq '.outbounds|=map(if .tag=="main-urltest-out" then .outbounds=["missing"] else . end)' "$FRONTEND" > "$work/next"; mv "$work/next" "$FRONTEND"
status | jq -e '.sections[0].activeNodeCount==null' >/dev/null
printf '%s\n' 'PASS: working graph counts are read-only, exclude selector duplication, and unavailable is not zero'
