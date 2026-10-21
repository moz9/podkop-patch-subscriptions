#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Reuse external-platform fixtures; execute the actual snapshot implementation.
sed -n '/^\. "\$repo\/openwrt\/podkop-service-snapshot.sh"$/,/^subscription_services_snapshot_save || fail /p' "$repo/tests/test_subscription_service_snapshot.sh" > "$tmp/setup"
. "$tmp/setup"
cp "$tmp/services" "$tmp/services.original"
rm "$tmp/services"
subscription_services_snapshot_prepare || fail 'diagnostic eviction invalidated exact admitted runtime'
jq -e '.sections[0].evidence[0].services.gemini.state=="pass"' "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json" >/dev/null || fail 'admission lacks frozen observations'
cp "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json" "$tmp/original"
jq '.sections[0].evidence[0].services.gemini.state="fail"' "$tmp/original" > "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json"
if subscription_services_snapshot_prepare; then fail 'corrupt admitted evidence accepted'; fi
cp "$tmp/original" "$PODKOP_SERVICE_SNAPSHOT_DIR/snapshot.json"
echo 'PASS: cache eviction cannot remove admission; corrupt frozen evidence is rejected'
