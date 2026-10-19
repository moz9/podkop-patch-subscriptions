#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo/openwrt/podkop-section-hooks.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
PODKOP_SECTION_RECOVERY_BASE="$work"
# Model root-owned 0700 journal metadata on non-root developer hosts too.
stat() { case "$2" in %u) echo "${journal_uid:-0}";; %a) echo 700;; *) command stat "$@";; esac; }
mkdir "$work/podkop-section-apply.case" "$work/root"
chmod 700 "$work/podkop-section-apply.case"
podkop_section_root() { echo "$work/root"; }
podkop_section_ready() { return 0; }
subscription_services_snapshot_section_commit() { cp "$2/snapshot-target.jsonl" "$work/committed"; }
echo main > "$work/podkop-section-apply.case/recovery-target"
echo '{"graph":1}' > "$work/podkop-section-apply.case/candidate.json"
echo '{"section":"main"}' > "$work/podkop-section-apply.case/snapshot-target.jsonl"
cp "$work/podkop-section-apply.case/candidate.json" "$work/root/logical.json"
cp "$work/root/logical.json" "$work/root/frontend.json"
PODKOP_SECTION_FRONTEND_CONFIG="$work/root/frontend.json"
if ! command -v podkop_section_recover_snapshot >/dev/null; then echo 'FAIL: interrupted active section snapshot has no recovery'; exit 1; fi
podkop_section_recover_snapshot
test -s "$work/committed"
test ! -e "$work/podkop-section-apply.case/recovery-target"
echo main > "$work/podkop-section-apply.case/recovery-target"
echo '{"graph":2}' > "$work/root/logical.json"
rm "$work/committed"
podkop_section_recover_snapshot
test ! -e "$work/committed"
test -e "$work/podkop-section-apply.case/recovery-target"
cp "$work/podkop-section-apply.case/candidate.json" "$work/root/logical.json"
journal_uid=1000
podkop_section_recover_snapshot
test ! -e "$work/committed"
echo 'PASS: interrupted snapshot recovery commits only exact active candidate'
