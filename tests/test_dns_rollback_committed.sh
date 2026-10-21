#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
PODKOP_DNS_APPLY_LIBRARY_ONLY=1
. "$repo/openwrt/podkop-dns-apply"
PODKOP_DNS_APPLY_BACKUP_DIR="$tmp/backups"
mkdir -p "$tmp/backups/transaction.test" "$tmp/root"
for file in runtime snapshot context uci; do printf '%s\n' "$file" > "$tmp/$file"; done
printf '1|json|%s/runtime\n2|snapshot|%s/snapshot\n3|context|%s/root/context.sha256\n4|uci|%s/uci\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/backups/transaction.test/files"
mv "$tmp/context" "$tmp/root/context.sha256"
sha256sum "$tmp/runtime" "$tmp/snapshot" "$tmp/root/context.sha256" "$tmp/uci" > "$tmp/backups/transaction.test/applied.sha"
printf 'transaction.test\n' > "$tmp/backups/latest"
dns_apply_load() { :; }
podkop_mutation_lock_acquire() { :; }
podkop_mutation_lock_release() { :; }
dns_apply_record_loaded() { :; }
dns_apply_restore() {
    [ "${DA_UCI:-}" = "$tmp/uci" ] &&
    [ "${PODKOP_DNS_COMMITTED_FILE:-}" = "$tmp/uci" ]
}
unset DA_UCI DA_CONFIG DA_ROOT DA_SNAPSHOT PODKOP_DNS_COMMITTED_FILE
dns_apply_main rollback > "$tmp/result" || { echo 'FAIL: fresh rollback did not bind its recorded committed UCI'; exit 1; }
jq -e '.success==true and .restored==true' "$tmp/result" >/dev/null
printf 'PASS: fresh rollback recovers recorded paths and binds committed UCI, not shared drafts\n'
