#!/bin/sh
# Reuse the transaction fixture's platform boundaries, not a copied validator.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_source="$repo/tests/test_legacy_dns_native_apply.sh"
[ -f "$fixture_source" ] || fixture_source="$repo/tests/test_pe_dns_apply.sh"
eval "$(awk '/^make_fixture prepare$/ || /^if .*DNS_APPLY_TEST_SAVED_ONLY/ {exit} {print}' "$fixture_source")"
# Real v2 context projection: only platform ubus transport is substituted.
eval "$(sed -n '/^podkop_section_context_hash() {$/,/^}$/p' "$repo/openwrt/podkop-section-hooks.sh")"
podkop_section_names() { printf '["main","GEOBLOCK"]\n'; }
podkop_section_enabled() { return 0; }
podkop_section_runtime_hash() {
    if jq -e '.mode=="single"' "$fixture/root/metadata.json" >/dev/null; then
        sha256sum "$1" "$fixture/root/logical.json" "$fixture/root/metadata.json" | sha256sum | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}
dns_apply_hash() { subscription_services_snapshot_hash "$1"; }
fixture_flat_uci() {
    awk '
      function clean(s) { gsub(/["\047]/,"",s); return s }
      $1=="config" { section=clean($3) }
      $1=="option" {
        key=clean($2); line=$0; sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]+/,"",line)
        print "podkop." section "." key "=" clean(line)
      }
    ' "$PODKOP_DNS_APPLY_UCI_FILE"
}
fixture_saved_set() {
    local section key
    section="$1"; section="${section#podkop.}"; key="${section#*.}"; section="${section%%.*}"
    awk -v wanted="$section" -v key="$key" -v value="$2" '
      function clean(s) { gsub(/["\047]/,"",s); return s }
      function append() { printf " option %s \047%s\047\n",key,value }
      $1=="config" { if(inside)append(); inside=(clean($3)==wanted); if(inside)found=1 }
      inside && $1=="option" && clean($2)==key { next }
      { print }
      END { if(inside)append(); if(!found){printf "config section \047%s\047\n",wanted;append()} }
    ' "$PODKOP_DNS_APPLY_UCI_FILE" > "$fixture/uci.new"
    mv "$fixture/uci.new" "$PODKOP_DNS_APPLY_UCI_FILE"
}
ubus() {
    fixture_flat_uci | jq -Rn '[inputs|split("=")|{path:(.[0]|split(".")|.[1:]),value:.[1: ]|join("=")}]
        | reduce .[] as $row ({values:{settings:{},main:{},GEOBLOCK:{}}}; setpath(["values"]+$row.path;$row.value))'
}
config_foreach() { "$1" main; "$1" GEOBLOCK; }
subscription_required_services_json() {
    case "$1" in main) printf '%s\n' "${required_main:-[\"gemini\"]}";; *) printf '%s\n' "${required_peer:-[]}";; esac
}
# Service context binds DNS/global settings, not section filter controls.
subscription_services_context() { { jq -cS '.dns' "$fixture/runtime.json"; fixture_flat_uci | awk '/^podkop.settings./'; } | sha256sum | awk '{print $1}'; }
make_fixture scoped-policy
printf '{"version":3,"mode":"single","sections":[{"section":"main"},{"section":"GEOBLOCK"}]}\n' > "$fixture/root/metadata.json"
printf 'single\n' > "$fixture/root/runtime-mode"
printf '{"version":3,"rules":[]}\n' > "$fixture/rules/admitted.json"
jq --arg path "$fixture/rules/admitted.json" '.route.rule_set=[{type:"local",path:$path}]' "$fixture/runtime.json" > "$fixture/new"
mv "$fixture/new" "$fixture/runtime.json"
cp "$fixture/runtime.json" "$fixture/root/logical.json"; cp "$fixture/runtime.json" "$fixture/root/frontend.json"
subscription_services_snapshot_save || fail 'scoped initial admission'
podkop_section_context_hash > "$fixture/root/context.sha256"
old_policy="$(jq -r .policy "$fixture/snapshot/snapshot.json")"
# Apply a main-only filter using the REAL scoped snapshot stage and commit.
fixture_saved_set podkop.main.subscription_include_tags SE
mkdir "$fixture/scoped"
subscription_services_preflight_section() { :; }
subscription_services_snapshot_section_stage main "$fixture/scoped" || fail 'scoped stage'
jq '.outbounds[0].outbounds=["main-urltest-out"]' "$fixture/runtime.json" > "$fixture/new"
mv "$fixture/new" "$fixture/runtime.json"
cp "$fixture/runtime.json" "$fixture/root/logical.json"; cp "$fixture/runtime.json" "$fixture/root/frontend.json"
subscription_services_snapshot_section_commit main "$fixture/scoped" || fail 'scoped commit'
[ "$(jq -r .policy "$fixture/snapshot/snapshot.json")" = "$old_policy" ] || fail 'scoped commit blessed full policy'
# A separately saved peer preference is still pending: DNS must preserve it.
fixture_saved_set podkop.GEOBLOCK.subscription_include_tags unapplied-peer-filter
printf '["GEOBLOCK"]\n' > "$fixture/subscription-pending"
sha256sum "$fixture/subscription-pending" > "$fixture/pending.sha"
cp "$fixture/uci" "$fixture/peer-intent.before"
if (dns_apply_scoped_policy_validate() { return 1; }; dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result"); then
    fail 'fixture did not exercise strict predecessor policy refusal'
fi
printf "podkop.GEOBLOCK.subscription_include_tags='draft-peer-filter'\n" > "$fixture/staged"
dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail 'valid scoped predecessor with unrelated draft refused'
rm "$fixture/staged"
for server in 9.9.9.9 9.9.9.10; do
    dns_apply_main apply dot "$server" tcp 8.8.8.8 > "$fixture/result" || fail 'scoped DNS successor refused'
    [ "$(jq -r .policy "$fixture/snapshot/snapshot.json")" = "$old_policy" ] || fail 'DNS blessed unrelated saved controls'
    jq -e --arg policy "$old_policy" '.continuity.kind=="dns-only" and .continuity.policyBasis.kind=="section-only" and .continuity.policyBasis.section=="main" and .continuity.policyBasis.policy==$policy' "$fixture/snapshot/snapshot.json" >/dev/null || fail 'scoped provenance lost'
    [ "$(fixture_uci_get podkop.GEOBLOCK.subscription_include_tags "$fixture/uci")" = unapplied-peer-filter ] || fail 'DNS lost peer preference'
    sha256sum -c "$fixture/pending.sha" >/dev/null || fail 'DNS cleared peer pending'
done
cp "$fixture/uci" "$fixture/uci.baseline"
cp "$fixture/runtime.json" "$fixture/runtime.baseline"
cp "$fixture/snapshot/snapshot.json" "$fixture/snapshot.baseline"
cp "$fixture/services" "$fixture/evidence.baseline"
reject() {
    if dns_apply_main prepare dot 9.9.9.11 tcp 8.8.8.8 > "$fixture/result"; then fail "admitted drift: $1"; fi
}
required_main='["chatgpt"]'; reject changed-required-basis; unset required_main
required_peer='["gemini"]'; reject new-required-peer; unset required_peer
for global in 'podkop.settings.enable_utls_fallback=1' 'podkop.settings.unknown_route_policy=changed'; do
    fixture_saved_set "${global%%=*}" "${global#*=}"; reject global-context; cp "$fixture/uci.baseline" "$fixture/uci"
done
printf 'pending-journal\n' > "$fixture/staged"; reject staged-delta; rm "$fixture/staged"
jq '.results[0].services.gemini.state="fail"' "$fixture/evidence.baseline" > "$fixture/services"; reject evidence; cp "$fixture/evidence.baseline" "$fixture/services"
printf '\n' >> "$fixture/runtime.json"; reject graph; cp "$fixture/runtime.baseline" "$fixture/runtime.json"
printf 'corrupt\n' > "$fixture/rules/admitted.json"; reject RAM-rule
generation="$(jq -r .generation "$fixture/snapshot/snapshot.json")"
cp "$fixture/snapshot/$generation/admitted.json" "$fixture/rules/admitted.json"
printf 'corrupt\n' > "$fixture/snapshot/$generation/admitted.json"; reject persistent-rule
cp "$fixture/rules/admitted.json" "$fixture/snapshot/$generation/admitted.json"
jq 'del(.continuity)' "$fixture/snapshot.baseline" > "$fixture/snapshot/snapshot.json"; reject generic-stale-policy
cp "$fixture/snapshot.baseline" "$fixture/snapshot/snapshot.json"
jq '.continuity.policyBasis.policy=("0"*64)' "$fixture/snapshot.baseline" > "$fixture/snapshot/snapshot.json"; reject forged-basis-policy
cp "$fixture/snapshot.baseline" "$fixture/snapshot/snapshot.json"
printf 'not-v2\n' > "$fixture/root/context.sha256"; reject legacy-context
podkop_section_context_hash > "$fixture/root/context.sha256"
dns_apply_main prepare dot 9.9.9.11 tcp 8.8.8.8 > "$fixture/result" || fail 'restored scoped proof rejected'
cmp "$fixture/uci.baseline" "$fixture/uci" || fail 'rejected prepare mutated UCI'
sha256sum -c "$fixture/pending.sha" >/dev/null || fail 'rejected prepare changed pending peer'
echo 'PASS: scoped policy DNS twice preserves unadmitted peer intent; required/global/evidence/graph/rules/provenance drift fail closed'
