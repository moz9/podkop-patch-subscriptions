#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_query() {
 echo "$1" >> "$work/queries"
 case "$1" in *.invalid|youtube.com) echo NXDOMAIN;; *) echo 'NOERROR|10';; esac
}
db_native_kind=bootstrap
db_native_measure > "$work/boot.json"
jq -e '.reliable and .nxdomainOk and .probeScope=="direct_bootstrap_dns_ordering_only"' "$work/boot.json" >/dev/null || fail 'usable bootstrap rejected by application-domain filtering'
! grep -Fxq youtube.com "$work/queries" || fail 'bootstrap used YouTube as mandatory service'
db_native_kind=main
db_native_measure > "$work/main.json"
jq -e '.reliable==false and .successCount==1' "$work/main.json" >/dev/null || fail 'main DNS acceptance silently weakened'
db_native_kind=bootstrap
db_query() { case "$1" in *.invalid) echo 'NOERROR|10';; *) echo 'NOERROR|10';; esac; }
db_native_measure > "$work/wildcard.json"
jq -e '.reliable==false and .nxdomainOk==false' "$work/wildcard.json" >/dev/null || fail 'wildcard/bootstrap hijack accepted'
echo 'PASS: bootstrap role separated from application-domain DNS; main and NXDOMAIN protections retained'
