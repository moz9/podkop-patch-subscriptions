#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PODKOP_DNS_APPLY_LIBRARY_ONLY=1 . "$repo/openwrt/podkop-dns-apply"
DA_WORK="$(mktemp -d)"; trap 'rm -rf "$DA_WORK"' EXIT INT TERM
DA_UCI="$DA_WORK/uci"; DA_SAVED=0
uci() { [ "$*" = '-q changes podkop' ]; }
printf 'candidate\n' | sha256sum | awk '{print $1}' > "$DA_WORK/uci-written.sha"
printf 'restored\n' > "$DA_UCI"
DA_UCI_RESTORED_SHA="$(sha256sum "$DA_UCI" | awk '{print $1}')"
dns_apply_uci_pending_clear || { echo 'FAIL: restored image is still compared to candidate'; exit 1; }
printf 'foreign edit\n' >> "$DA_UCI"
! dns_apply_uci_pending_clear || { echo 'FAIL: foreign post-restore edit accepted'; exit 1; }
echo 'PASS: post-restore readiness binds restored UCI and rejects later foreign edits'
