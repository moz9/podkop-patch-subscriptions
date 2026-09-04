#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
file="$repo/openwrt/podkop-subscription-probe.sh"
[ -f "$file" ] || { echo 'FAIL: isolated subscription probe missing'; exit 1; }
sh -n "$file"
! grep -Eq 'uci .* (set|commit)|clash_api_set|/etc/init.d/|/usr/bin/podkop reload' "$file"
grep -Fq '127.0.0.1' "$file"
grep -Fq 'default_mark' "$file"
grep -Fq 'kill "$probe_pid"' "$file"
grep -Fq '.supported == true' "$file"
! grep -Fq '.enabled == true' "$file"
echo 'PASS: isolated probe does not select production outbounds or restart services'
