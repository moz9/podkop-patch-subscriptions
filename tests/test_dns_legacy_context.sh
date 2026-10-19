#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Reuse real transaction/snapshot functions and only the platform doubles.
eval "$(awk '/^if .*DNS_APPLY_TEST_SAVED_ONLY/ {exit} {print}' "$repo/tests/test_pe_dns_apply.sh")"
podkop_section_names() { printf '["main"]\n'; }
podkop_section_context_hash() { printf 'v2:'; sha256sum "$PODKOP_DNS_APPLY_UCI_FILE" | awk '{print $1}'; }

legacy_fixture() {
    make_fixture "legacy-$1"
    printf '{"version":3,"mode":"single","sections":[{"section":"main"}]}\n' > "$fixture/root/metadata.json"
    printf 'single\n' > "$fixture/root/runtime-mode"
    printf '{"version":3,"rules":[]}\n' > "$fixture/rules/admitted.json"
    jq --arg path "$fixture/rules/admitted.json" '.route.rule_set=[{type:"local",path:$path}]' "$fixture/runtime.json" > "$fixture/new"
    mv "$fixture/new" "$fixture/runtime.json"
    cp "$fixture/runtime.json" "$fixture/root/logical.json"; cp "$fixture/runtime.json" "$fixture/root/frontend.json"
    subscription_services_snapshot_save || fail 'legacy snapshot fixture'
    jq --arg hash "$(dns_apply_hash "$fixture/runtime.json")" '.config=$hash|.sections|=map(del(.evidence))|.continuity={mode:"section-only",section:"main"}' "$fixture/snapshot/snapshot.json" > "$fixture/new"
    mv "$fixture/new" "$fixture/snapshot/snapshot.json"
    printf '%064d\n' 7 > "$fixture/root/context.sha256"
    # Historical state: saved shared routing differs from admitted runtime.
    # DNS must not certify this desired setting as active or regenerate routes.
    printf " option unknown_route_policy 'unapplied'\n" >> "$fixture/uci"
    cp "$fixture/uci" "$fixture/original-uci"
    cp "$fixture/runtime.json" "$fixture/original-runtime"
    cp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot"
    sha256sum "$fixture/root/context.sha256" "$fixture/root/metadata.json" "$fixture/services" > "$fixture/protected.sha"
}
for outcome in success reload-fail; do
    legacy_fixture "$outcome"
    printf "podkop.main.subscription_selected_link_ids='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\n" > "$fixture/draft-only"
    sha256sum "$fixture/draft-only" >> "$fixture/protected.sha"
    dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'legacy scoped predecessor cannot prepare'
    cmp "$fixture/uci" "$fixture/original-uci" || fail 'prepare changed UCI'
    [ ! -e "$fixture/reloads" ] && [ ! -e "$fixture/backup" ] || fail 'prepare changed service/persistent state'
    if [ "$outcome" = reload-fail ]; then
        : > "$fixture/reload-fail"
        ! dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail 'failed activation accepted'
        jq -e '.error=="apply_failed_rolled_back" and .restored==true' "$fixture/result" >/dev/null || fail 'failed activation recovery misreported'
    else
        dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail 'legacy both-pair apply refused'
        jq -e '.success==true and .changed==true' "$fixture/result" >/dev/null || fail 'legacy apply did not report success'
        grep -q "option secondary_dns_server '1.1.1.1'" "$fixture/uci" || fail 'reserve not saved'
        grep -q "option unknown_route_policy 'unapplied'" "$fixture/uci" || fail 'saved routing lost'
        jq -S 'del(.dns)' "$fixture/runtime.json" > "$fixture/route.after"
        jq -S 'del(.dns)' "$fixture/original-runtime" > "$fixture/route.before"
        cmp "$fixture/route.before" "$fixture/route.after" || fail 'DNS activated unrelated routing'
        jq -S 'del(.config,.continuity)' "$fixture/snapshot/snapshot.json" > "$fixture/snapshot.after"
        jq -S 'del(.config,.continuity)' "$fixture/original-snapshot" > "$fixture/snapshot.before"
        cmp "$fixture/snapshot.before" "$fixture/snapshot.after" || fail 'legacy DNS blessed current policy or changed admission'
        dns_apply_main prepare dot 9.9.9.10 tcp 8.8.8.8 > "$fixture/result" || fail 'second legacy DNS operation refused'
        dns_apply_main rollback > "$fixture/result" || fail 'legacy exact rollback refused'
    fi
    cmp "$fixture/uci" "$fixture/original-uci" || fail 'legacy UCI not restored'
    cmp "$fixture/runtime.json" "$fixture/original-runtime" || fail 'legacy runtime not restored'
    cmp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot" || fail 'legacy snapshot not restored'
    sha256sum -c "$fixture/protected.sha" >/dev/null || fail 'legacy context/metadata/evidence changed'
done
echo 'PASS: legacy scoped both-pair apply, next prepare and exact rollback preserve unapplied shared settings'

for invalid in provenance context graph evidence ram-rule disk-rule required draft; do
    legacy_fixture "reject-$invalid"
    case "$invalid" in
      provenance) jq 'del(.continuity)' "$fixture/original-snapshot" > "$fixture/snapshot/snapshot.json";;
      context) printf 'v2:%064d\n' 8 > "$fixture/root/context.sha256";;
      graph) printf '\n' >> "$fixture/runtime.json";;
      evidence) jq '.results[].services.gemini.state="fail"' "$fixture/services" > "$fixture/new"; mv "$fixture/new" "$fixture/services";;
      ram-rule) printf 'corrupt\n' > "$fixture/rules/admitted.json";;
      disk-rule) generation="$(jq -r .generation "$fixture/snapshot/snapshot.json")"; printf 'corrupt\n' > "$fixture/snapshot/$generation/admitted.json";;
      required) jq '.sections[0].requiredServices=["chatgpt"]' "$fixture/original-snapshot" > "$fixture/snapshot/snapshot.json";;
      draft) printf "podkop.settings.dns_server='user-draft'\n" > "$fixture/staged";;
    esac
    cp "$fixture/uci" "$fixture/reject-before"
    ! dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail "legacy accepted $invalid"
    cmp "$fixture/uci" "$fixture/reject-before" || fail "legacy rejection changed UCI: $invalid"
    [ ! -e "$fixture/reloads" ] && [ ! -e "$fixture/backup" ] || fail "legacy rejection mutated: $invalid"
done
echo 'PASS: legacy fallback rejects missing provenance, v2 drift, changed graph/evidence/rules/requirements and DNS drafts'

legacy_fixture restore-foreign
dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail 'restore race setup'
eval "$(declare -f dns_apply_reload | sed '1s/dns_apply_reload/dns_apply_reload_without_foreign/')"
dns_apply_reload() {
    dns_apply_reload_without_foreign || return 1
    printf '# foreign edit during rollback activation\n' >> "$PODKOP_DNS_APPLY_UCI_FILE"
}
! dns_apply_main rollback > "$fixture/result" || fail 'rollback certified foreign post-restore UCI'
jq -e '.error=="rollback_failed" and .restored==false' "$fixture/result" >/dev/null || fail 'foreign rollback result is not truthful'
grep -q '# foreign edit during rollback activation' "$fixture/uci" || fail 'foreign edit was erased'
echo 'PASS: post-restore foreign UCI edit is retained and never reported as verified rollback'
