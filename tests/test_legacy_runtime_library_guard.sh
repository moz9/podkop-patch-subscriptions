#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
for version in 0.7.20 0.7.22; do
 file="$root/openwrt/runtime-$version/usr/bin/podkop"
 grep -Fq '[ "${PODKOP_LIBRARY_ONLY:-0}" != 1 ] || return 0' "$file" || { echo "FAIL: legacy $version cannot be sourced safely by paired DNS helper"; exit 1; }
done
echo 'PASS: both legacy runtimes support read-only helper sourcing'
