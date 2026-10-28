#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
fixture_source="$repo/tests/test_legacy_dns_native_apply.sh"
[ -f "$fixture_source" ] || fixture_source="$repo/tests/test_pe_dns_apply.sh"
eval "$(awk '/^make_fixture prepare$/ || /^if .*DNS_APPLY_TEST_SAVED_ONLY/ {exit} {print}' "$fixture_source")"
make_fixture empty-receipt
printf '{"version":3,"mode":"single","sections":[{"section":"main"}]}\n' > "$fixture/root/metadata.json"
echo single > "$fixture/root/runtime-mode"
subscription_required_services_json() { printf '%s\n' "${fixture_required:-[]}"; return "${fixture_required_rc:-0}"; }
fixture_required='[]'
podkop_section_context_hash() { printf 'v2:'; sha256sum "$PODKOP_DNS_APPLY_UCI_FILE" | awk '{print $1}'; }
jq '.sections=[]|.config=("0"*64)|.policy=("1"*64)' "$fixture/snapshot/snapshot.json" > "$fixture/new"
mv "$fixture/new" "$fixture/snapshot/snapshot.json"
cp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot"
podkop_section_context_hash > "$fixture/root/context.sha256"
DA_ROOT="$fixture/root"; DA_DNS_TRANSACTION_GRAPH=0
! dns_apply_empty_current "$fixture/snapshot/snapshot.json" || fail 'reserve binding inherited DNS-only exemption'
dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'stale empty non-admission blocked exact unfiltered DNS prepare'
assert_restored
[ ! -e "$fixture/reloads" ] && [ ! -e "$fixture/backup" ] || fail 'prepare changed runtime or created persistent transaction'
fixture_required='["chatgpt"]'
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'empty receipt bypassed selected service'
fixture_required='[]'; fixture_required_rc=1
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'failed service requirement read accepted'
fixture_required_rc=0
echo drift >> "$fixture/root/context.sha256"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'context drift accepted'
podkop_section_context_hash > "$fixture/root/context.sha256"
jq '.outbounds[2].server="changed.invalid"' "$fixture/root/logical.json" > "$fixture/new"
mv "$fixture/new" "$fixture/root/logical.json"
! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'graph aliases diverged but were accepted'
cp "$fixture/runtime.json" "$fixture/root/logical.json"
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'empty unfiltered DNS apply'
dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'repeat identical empty unfiltered DNS apply'
jq -e '.sections==[] and .continuity.freshServiceEvidence==false' "$fixture/snapshot/snapshot.json" >/dev/null || fail 'DNS manufactured service evidence'
dns_apply_main rollback > "$fixture/result" || fail 'empty unfiltered rollback'
assert_restored
echo 'PASS: stale empty non-admission does not block DNS; context/aliases/service gates remain strict; apply/rollback preserve pools'
