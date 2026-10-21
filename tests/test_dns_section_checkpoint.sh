#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
eval "$(awk '/^make_fixture scoped-policy$/ {exit} {print}' "$repo/tests/test_dns_scoped_policy.sh")"
make_fixture section-checkpoint
printf '{"version":3,"mode":"single","sections":[{"section":"main"},{"section":"GEOBLOCK"}]}\n' > "$fixture/root/metadata.json"
printf 'single\n' > "$fixture/root/runtime-mode"
printf '{"version":3,"rules":[]}\n' > "$fixture/rules/admitted.json"
jq --arg path "$fixture/rules/admitted.json" '.route.rule_set=[{type:"local",path:$path}]' "$fixture/runtime.json" > "$fixture/new"
mv "$fixture/new" "$fixture/runtime.json"
cp "$fixture/runtime.json" "$fixture/root/logical.json"; cp "$fixture/runtime.json" "$fixture/root/frontend.json"
subscription_services_snapshot_save || fail 'initial snapshot'
podkop_section_context_hash > "$fixture/root/context.sha256"
cp "$fixture/root/context.sha256" "$fixture/original-context"
# A manual-node edit changes desired section structure, not DNS or peer runtime.
fixture_saved_set podkop.main.urltest_proxy_links fixture-manual-node
mkdir "$fixture/scoped"
subscription_services_preflight_section() { :; }
subscription_services_snapshot_section_stage main "$fixture/scoped" || fail 'section stage'
subscription_services_snapshot_section_commit main "$fixture/scoped" || fail 'section commit'
jq -e --arg desired "$(podkop_section_context_hash)" --arg checkpoint "$(cat "$fixture/original-context")" \
 '.continuity.trafficContext=={checkpoint:$checkpoint,desired:$desired}' "$fixture/snapshot/snapshot.json" >/dev/null || fail 'missing scoped traffic checkpoint'
cp "$fixture/snapshot/snapshot.json" "$fixture/scoped-snapshot"
cp "$fixture/uci" "$fixture/scoped-uci"
mkdir "$fixture/stage-race"
subscription_services_snapshot_section_stage main "$fixture/stage-race" || fail 'race stage'
fixture_saved_set podkop.settings.unknown_route_policy concurrent-edit
! subscription_services_snapshot_section_commit main "$fixture/stage-race" || fail 'concurrent saved intent was certified'
cmp "$fixture/scoped-snapshot" "$fixture/snapshot/snapshot.json" || fail 'failed commit changed snapshot'
cp "$fixture/scoped-uci" "$fixture/uci"
for invalid in context provenance evidence graph; do
 case "$invalid" in
  context) fixture_saved_set podkop.settings.unknown_route_policy later-edit;;
  provenance) jq 'del(.continuity.trafficContext)' "$fixture/scoped-snapshot" > "$fixture/snapshot/snapshot.json";;
  evidence) jq '.results[].services.gemini.state="fail"' "$fixture/services" > "$fixture/new"; cp "$fixture/services" "$fixture/evidence-original"; mv "$fixture/new" "$fixture/services";;
  graph) printf '\n' >> "$fixture/runtime.json";;
 esac
 ! dns_apply_main prepare dot 9.9.9.9 tcp 8.8.8.8 > "$fixture/result" || fail "accepted $invalid"
 [ ! -e "$fixture/reloads" ] && [ ! -e "$fixture/backup" ] || fail "mutated on $invalid"
 cp "$fixture/scoped-uci" "$fixture/uci"; cp "$fixture/scoped-snapshot" "$fixture/snapshot/snapshot.json"
 [ "$invalid" != evidence ] || cp "$fixture/evidence-original" "$fixture/services"
 [ "$invalid" != graph ] || cp "$fixture/root/logical.json" "$fixture/runtime.json"
done
for server in 9.9.9.9 9.9.9.10; do
 dns_apply_main apply_pairs dot "$server" tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail 'scoped two-pair successor refused'
 cmp "$fixture/root/context.sha256" "$fixture/original-context" || fail 'DNS certified unrelated desired intent as applied'
 jq -e --arg desired "$(podkop_section_context_hash)" '.continuity.policyBasis.trafficContext.desired==$desired and .continuity.preservedTrafficContext==true' "$fixture/snapshot/snapshot.json" >/dev/null || fail 'successor lost scoped checkpoint'
done
dns_apply_main rollback > "$fixture/result" || fail 'local exact rollback refused'
cmp "$fixture/root/context.sha256" "$fixture/original-context" || fail 'rollback changed original checkpoint'
echo 'PASS: section-only structural admission supports bounded DNS successors; later context/evidence/graph/provenance drift rejected'
