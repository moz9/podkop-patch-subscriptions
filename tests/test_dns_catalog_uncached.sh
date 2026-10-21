#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/optimizer"
PODKOP_DNS_BENCHMARK_OPTIMIZER="$tmp/optimizer" PODKOP_DNS_CATALOG_DIR="$repo/openwrt" \
 PODKOP_DNS_BENCHMARK_STATE_DIR="$tmp/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$tmp/persist" \
 sh "$repo/openwrt/podkop-dns-benchmark" catalog > "$tmp/catalog"
jq -e '.success==true and (.availableResults|length)>10 and (.availableBootstrapResults|length)>10 and
 all((.availableResults+.availableBootstrapResults)[];.measured==false and .reliable==false and .automaticEligible==false) and
 all(.availableResults[]; .primaryEligible==true and (.id|ascii_downcase|startswith("yandex")|not)) and
 (has("reportId")|not) and (has("recommendation")|not)' "$tmp/catalog" >/dev/null
[ ! -e "$tmp/state" ] && [ ! -e "$tmp/persist" ]
printf 'PASS: manual DNS catalog works without caches, measurements, runtime or state writes\n'
