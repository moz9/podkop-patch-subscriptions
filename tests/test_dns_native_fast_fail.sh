#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^db_native_measure() {$/,/^}$/p' "$repo/openwrt/podkop-dns-benchmark" > "$work/functions"
. "$work/functions"
db_query() { echo "$1" >> "$work/calls"; echo 'ERROR|TIMEOUT'; return 1; }
db_native_measure > "$work/result"
test "$(wc -l < "$work/calls" | tr -d ' ')" = 1 || { echo 'FAIL: dead native endpoint still receives three timeout probes'; exit 1; }
jq -e '.reliable==false and .totalQueries==1 and .nxdomainTested==false and .httpsTested==false' "$work/result" >/dev/null
: > "$work/calls"
db_query() { echo "$1" >> "$work/calls"; case "$1" in *.invalid) echo NXDOMAIN;; *) echo 'NOERROR|20';; esac; }
db_native_measure > "$work/result"
test "$(wc -l < "$work/calls" | tr -d ' ')" = 3
jq -e '.reliable==true and .totalQueries==2 and .nxdomainTested==true and .fullCompatibilityVerified==false' "$work/result" >/dev/null
echo 'PASS: native DNS stops at first failure; responsive endpoints retain both names and NXDOMAIN'
