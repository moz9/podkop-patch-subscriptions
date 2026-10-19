#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
. "$repo/openwrt/podkop-service-snapshot.sh"
podkop_section_enabled() { return 0; }
podkop_section_context_matches() { return 1; }
podkop_section_root() { echo "$work"; }
podkop_section_context_hash() { echo "$context"; }
log() { :; }
context="v2:$(printf '%064d' 1)"; printf '%s\n' "$context" > "$work/context.sha256"
subscription_services_continuity_context_ready || { echo 'FAIL: unchanged applied traffic with pending selection blocked continuity'; exit 1; }
context="v2:$(printf '%064d' 2)"
! subscription_services_continuity_context_ready || { echo 'FAIL: changed traffic accepted'; exit 1; }
echo 'PASS: pending selection does not block exact-context continuity; changed traffic still refused'
