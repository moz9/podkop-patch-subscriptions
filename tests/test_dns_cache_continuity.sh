#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
eval "$(awk '/^for outcome in / {exit} {print}' "$repo/tests/test_dns_legacy_context.sh")"

# Old snapshots authenticate the admitted graph but carry only the observation
# digest, not the original rows. Re-tests must not rewrite that admission.
for state in refreshed unknown evicted; do
    legacy_fixture "cache-$state"
    case "$state" in
      refreshed) jq '.results[].checkedAt=500 | .results[].expiresAt=900' "$fixture/services" > "$fixture/cache-new";;
      unknown) jq '.results[].services.gemini={state:"unknown",reason:"challenge_required",httpCode:429}' "$fixture/services" > "$fixture/cache-new";;
      evicted) printf '{"results":[]}\n' > "$fixture/cache-new";;
    esac
    mv "$fixture/cache-new" "$fixture/services"
    sha256sum "$fixture/services" > "$fixture/cache.sha"
    dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" || fail "mutable $state cache blocked exact DNS continuation"
    jq -e '.success==true and .changed==true' "$fixture/result" >/dev/null || fail 'apply result'
    jq -S '{policy,sections,rules}' "$fixture/snapshot/snapshot.json" > "$fixture/admission-after"
    jq -S '{policy,sections,rules}' "$fixture/original-snapshot" > "$fixture/admission-before"
    cmp "$fixture/admission-before" "$fixture/admission-after" || fail 'DNS re-certified mutable service observations'
    dns_apply_main rollback > "$fixture/result" || fail 'cache-independent rollback'
    cmp "$fixture/original-uci" "$fixture/uci" || fail 'UCI rollback'
    cmp "$fixture/original-runtime" "$fixture/runtime.json" || fail 'runtime rollback'
    cmp "$fixture/original-snapshot" "$fixture/snapshot/snapshot.json" || fail 'admission rollback'
    sha256sum -c "$fixture/cache.sha" >/dev/null || fail 'DNS rewrote diagnostic cache'
done

for invalid in denial malformed frozen-corruption; do
    legacy_fixture "cache-$invalid"
    case "$invalid" in
      denial) jq '.results[].services.gemini.state="fail"' "$fixture/services" > "$fixture/cache-new"; mv "$fixture/cache-new" "$fixture/services";;
      malformed) printf '{bad json\n' > "$fixture/services";;
      frozen-corruption) jq --slurpfile c "$fixture/services" '.sections[0].evidence=$c[0].results | .sections[0].evidence[0].checkedAt=999' "$fixture/snapshot/snapshot.json" > "$fixture/new"; mv "$fixture/new" "$fixture/snapshot/snapshot.json";;
    esac
    ! dns_apply_main apply_pairs dot 9.9.9.9 tcp 8.8.8.8 udp 1.1.1.1 udp 8.8.4.4 > "$fixture/result" 2> "$fixture/expected-refusal.log" || fail "accepted $invalid"
    [ ! -e "$fixture/reloads" ] && [ ! -e "$fixture/backup" ] || fail "mutated on $invalid"
    cmp "$fixture/original-uci" "$fixture/uci" || fail "changed UCI on $invalid"
done
echo 'PASS: DNS preserves legacy admission across cache refresh/unknown/eviction; denial and corrupt frozen evidence still block'
