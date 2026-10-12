# Sourced by the native DNS transaction fixture: retain its real transaction,
# CAS, snapshot and rollback functions, mocking only platform boundaries.
dns_apply_hash() {
    if [ "$1" = "$fixture/runtime.json" ] && jq -e '.version==3 and .mode=="single"' "$fixture/root/metadata.json" >/dev/null; then
        sha256sum "$1" "$fixture/root/logical.json" "$fixture/root/metadata.json" | sha256sum | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}
for single_case in admitted empty reload-fail; do
    make_fixture "single-$single_case"
    printf '{"version":3,"mode":"single","sections":[{"section":"main","api_port":9090},{"section":"GEOBLOCK","api_port":9090}],"allocations":[]}\n' > "$fixture/root/metadata.json"
    printf 'single\n' > "$fixture/root/runtime-mode"
    mkdir -p "$fixture/root/workers/main"
    printf 'dormant split worker must never be read or changed\n' > "$fixture/root/workers/main/worker.json"
    printf 'pending main and GEOBLOCK selections\n' > "$fixture/pending-selection"
    sha256sum "$fixture/root/workers/main/worker.json" "$fixture/pending-selection" "$fixture/root/metadata.json" "$fixture/root/runtime-mode" > "$fixture/protected.sha"
    single_hash="$(dns_apply_hash "$fixture/runtime.json")"
    jq --arg hash "$single_hash" --arg kind "$single_case" '.config=$hash|if $kind=="admitted" then . else .sections=[] end' "$fixture/snapshot/snapshot.json" > "$fixture/new"
    mv "$fixture/new" "$fixture/snapshot/snapshot.json"
    cp "$fixture/snapshot/snapshot.json" "$fixture/original-snapshot"
    (
        DA_ROOT="$fixture/root"; DA_CONFIG="$fixture/runtime.json"
        PODKOP_DNS_APPLY_MAIN_INIT=dns_single_main
        PODKOP_SECTION_INIT=dns_single_worker
        PODKOP_SECTION_MANAGER=dns_single_manager
        dns_single_main() { printf '%s\n' "$*" >> "$fixture/main-calls"; }
        dns_single_worker() { fail 'single DNS touched worker service'; }
        dns_single_manager() {
            [ "$*" = wait-ready ] && [ "$PODKOP_SECTION_ROOT" = "$fixture/root" ] &&
            [ "$PODKOP_SECTION_FRONTEND_CONFIG" = "$fixture/runtime.json" ] &&
            [ ! -f "$fixture/manager-not-ready" ]
        }
        dns_apply_runtime_reload && dns_apply_runtime_ready || fail 'single service boundary'
        : > "$fixture/manager-not-ready"
        ! dns_apply_runtime_ready || fail 'single readiness accepted failed listener/API proof'
    ) || fail 'single service boundary fixture'
    dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail "single $single_case prepare"
    assert_restored
    [ ! -e "$fixture/reloads" ] || fail 'single prepare reloaded runtime'
    if [ "$single_case" = reload-fail ]; then
        : > "$fixture/reload-fail"
        ! dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'single failed reload accepted'
    else
        dns_apply_main apply dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail "single $single_case apply"
        jq -e '.dns.servers[]|select(.tag=="dns-server")|.server=="9.9.9.9"' "$fixture/runtime.json" >/dev/null || fail 'single DNS not activated'
        cmp "$fixture/runtime.json" "$fixture/root/logical.json" && cmp "$fixture/runtime.json" "$fixture/root/frontend.json" || fail 'single aliases diverged'
        [ "$(jq -r .config "$fixture/snapshot/snapshot.json")" = "$(dns_apply_hash "$fixture/runtime.json")" ] || fail 'single compound admission hash stale'
        dns_apply_main rollback > "$fixture/result" || fail "single $single_case rollback"
    fi
    assert_restored
    sha256sum -c "$fixture/protected.sha" >/dev/null || fail 'single DNS changed dormant worker, registry or pending selections'
    if [ "$single_case" = empty ]; then
        # Empty admission is not an exemption from exact rule-file continuity.
        printf '{"version":3,"rules":[]}\n' > "$fixture/rules/admitted.json"
        jq --arg path "$fixture/rules/admitted.json" '.route.rule_set=[{type:"local",path:$path}]' "$fixture/runtime.json" > "$fixture/new"
        mv "$fixture/new" "$fixture/runtime.json"
        cp "$fixture/runtime.json" "$fixture/root/logical.json"; cp "$fixture/runtime.json" "$fixture/root/frontend.json"
        generation="$(jq -r .generation "$fixture/snapshot/snapshot.json")"
        cp "$fixture/rules/admitted.json" "$fixture/snapshot/$generation/admitted.json"
        jq --arg hash "$(dns_apply_hash "$fixture/runtime.json")" --arg rule "$(dns_apply_hash "$fixture/rules/admitted.json")" '.config=$hash|.rules=[{name:"admitted.json",sha:$rule}]' "$fixture/snapshot/snapshot.json" > "$fixture/new"
        mv "$fixture/new" "$fixture/snapshot/snapshot.json"
        dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'valid empty single rule continuity refused'
        printf 'corrupt\n' > "$fixture/snapshot/$generation/admitted.json"
        ! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'empty single accepted corrupt persistent rule'
        cp "$fixture/rules/admitted.json" "$fixture/snapshot/$generation/admitted.json"
        printf 'corrupt\n' > "$fixture/rules/admitted.json"
        ! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'empty single accepted corrupt RAM rule'
    fi
    printf 'split\n' > "$fixture/root/runtime-mode"
    ! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'v3 with missing single marker accepted'
done
echo 'PASS: single v3 admitted/empty DNS transactions and rollback preserve pending and dormant workers'
