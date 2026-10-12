#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for catalog in dns-main.json dns-bootstrap.json; do
    grep -Eq "^[[:space:]]+$catalog[[:space:]]+" "$root/s" || {
        printf 'FAIL: safe updater does not prefetch %s\n' "$catalog" >&2
        exit 1
    }
done
printf 'PASS: DNS catalogs delivered by safe updater\n'
