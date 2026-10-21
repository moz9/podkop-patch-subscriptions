#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Reuse only the UCI boundary fixture and real transaction functions.
sed '/^reset_case$/,$d' "$repo/tests/test_dns_atomic_uci.sh" | sed '1,4d' > "$work/setup"
. "$work/setup"
podkop_section_names() { echo '["main"]'; }
command -v dns_apply_pending_capture >/dev/null || fail 'scoped draft admission absent'
reset_case
printf "podkop.main.subscription_selected_link_ids='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\n" > "$fixture_pending"
cp "$fixture_pending" "$work/expected"
dns_apply_pending_capture || fail 'unrelated selection draft rejected'
dns_apply_uci_set || fail 'captured unrelated draft blocked DNS write'
cmp "$fixture_pending" "$work/expected" || fail 'draft changed'
grep -q "option dns_server '9.9.9.9'" "$DA_UCI" || fail 'DNS not committed'
[ ! -s "$mutations" ] || fail 'shared UCI journal mutated'
# Later even harmless edits invalidate this transaction, without losing them.
printf "podkop.main.subscription_include_tags='new'\n" >> "$fixture_pending"
! dns_apply_uci_pending_clear || fail 'concurrent edit accepted'
for change in "podkop.settings.dns_server='conflict'" "podkop.main.community_lists='changed'" "podkop.main='section'" "-podkop.main" "podkop.peer.subscription_selected_link_ids='unknown-section'"; do
    reset_case
    printf '%s\n' "$change" > "$fixture_pending"
    ! dns_apply_pending_capture || fail "conflict accepted: $change"
done
for change in "podkop.main.subscription_selected_link_ids+='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'" "podkop.main.subscription_include_tags-='old'" "-podkop.main.subscription_required_services"; do
    reset_case
    printf '%s\n' "$change" > "$fixture_pending"
    cp "$fixture_pending" "$work/list-draft"
    dns_apply_pending_capture && dns_apply_uci_set || fail 'safe list/removal draft blocked DNS'
    cmp "$fixture_pending" "$work/list-draft" || fail 'list/removal draft changed'
done
for change in "podkop.main.community_lists+='google_ai'" "-podkop.settings.dns_server" "-podkop.main"; do
    ! dns_apply_pending_safe "$change" || fail 'routing/DNS/structural deletion admitted'
done
echo 'PASS: unrelated registered-section drafts preserved; DNS/routing/structural and concurrent edits rejected'
