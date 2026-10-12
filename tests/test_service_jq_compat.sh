#!/bin/sh
# Real service admission functions must fail closed on jq 1.6 and newer.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export PODKOP_SERVICE_CACHE_DIR="$work/state"
mkdir "$PODKOP_SERVICE_CACHE_DIR"
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '[{"id":"%s","supported":true}]\n' "$id" > "$work/items"
validate_subscription_section_name() { [ "$1" = main ]; }
validate_subscription_urltest_section() { [ "$1" = main ]; }
validate_subscription_link_id() { [ "$1" = "$id" ]; }
subscription_runtime_busy() { return 1; }
subscription_action_lock_acquire() { return 0; }
subscription_action_lock_release() { :; }
get_subscription_items_cache_path() { printf '%s/items\n' "$work"; }
subscription_reload_pending_file() { printf '%s/pending\n' "$work"; }
subscription_pending_mark() { (umask 077; touch "$work/pending"); }

for production in "$repo/openwrt/podkop-service-checks.sh" "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    # Never source a router entrypoint. Only the exact shipped library block.
    sed -n '/^# subscription_services_v1 begin$/,/^# subscription_services_v1 end$/p' "$production" > "$work/services"
    grep -Fqx 'subscription_services_confirm() (' "$work/services" || fail "service block missing: $production"
    . "$work/services"
    subscription_services_context() { printf 'fixture-context\n'; }
    subscription_required_services_json() { printf '["gemini"]\n'; }
    path="$(subscription_services_cache_path main)"
    now="$(date +%s)"
    for scenario in missing expired duplicate fresh; do
      for enabled in true false; do
        jq -cn --arg id "$id" --arg scenario "$scenario" --argjson now "$now" '
            {context:"fixture-context",results:[{id:$id,checkedAt:$now,expiresAt:($now+3600),services:{gemini:{state:"unknown",network:"pass"}}}]}
            | if $scenario=="missing" then .results=[]
              elif $scenario=="expired" then .results[0].expiresAt=0
              elif $scenario=="duplicate" then .results+=.results else . end
        ' > "$path"
        cp "$path" "$work/before-cache"
        printf 'existing pending marker\n' > "$work/pending"
        cp "$work/pending" "$work/before-pending"
        if [ "$scenario" = fresh ]; then
            subscription_services_confirm main "$id" gemini "$enabled" > "$work/result" || fail "fresh confirmation rejected: $production"
            jq -e '.success==true' "$work/result" >/dev/null || fail 'fresh confirmation did not report success'
            jq -e --argjson enabled "$enabled" --slurpfile before "$work/before-cache" '
                .results[0].checkedAt==$before[0].results[0].checkedAt and
                .results[0].expiresAt==$before[0].results[0].expiresAt and
                .results[0].services.gemini=={state:(if $enabled then "pass" else "fail" end),network:"pass",manual:true,reason:"user_confirmed"}
            ' "$path" >/dev/null || fail 'fresh confirmation changed observation lifetime or wrong state'
        else
            if subscription_services_confirm main "$id" gemini "$enabled" > "$work/result"; then fail "$scenario evidence confirmed: $production"; fi
            jq -e '.success==false and .error=="recent_network_check_required"' "$work/result" >/dev/null || fail "$scenario refusal lost exact error"
            cmp -s "$path" "$work/before-cache" || fail "$scenario refusal mutated cache"
            cmp -s "$work/pending" "$work/before-pending" || fail "$scenario refusal mutated pending marker"
        fi
      done
    done
    for input in '' ' ' 'null' '{}' '1' '"gemini"' '[] []' '["gemini","gemini"]' '["unsupported"]'; do
        if subscription_services_validate "$input"; then fail "invalid service input accepted: $production [$input]"; fi
    done
    for input in '[]' '["gemini"]' '["gemini","chatgpt"]'; do
        subscription_services_validate "$input" || fail "valid service input rejected: $production [$input]"
    done
    for body in '' ' ' 'null' '[]' '1' '"models"' '{bad-json}' '{"models":[]}' '{"models":[{}]}' '{"models":[{"id":"model"}]} {"models":[{"id":"model"}]}'; do
        subscription_services_classify chatgpt 0 200 "$body" > "$work/result" || fail 'classifier execution failed'
        jq -e '.state!="pass" and .reason!="anonymous_models_available"' "$work/result" >/dev/null || fail "invalid models body admitted: $production [$body]"
    done
    for body in '{"models":[{"id":"model"}]}' '{"models":[{"slug":"model"}]}'; do
        subscription_services_classify chatgpt 0 200 "$body" > "$work/result"
        jq -e '.state=="pass" and .reason=="anonymous_models_available"' "$work/result" >/dev/null || fail "valid models body rejected: $production"
    done
    # Exercise the actual evidence reader, configured policy and source filter.
    # An invalid cache must preserve the configured requirement and admit no node.
    policy_source="$production"
    [ "$production" != "$repo/openwrt/podkop-service-checks.sh" ] || policy_source="$repo/openwrt/podkop-subscription-sources.sh"
    sed -n '/^subscription_source_policy() {$/,/^}$/p' "$policy_source" > "$work/source-policy"
    . "$work/source-policy"
    subscription_required_services_json() { printf '["chatgpt"]\n'; }
    jq -cn --arg id "$id" --argjson now "$now" '{context:"fixture-context",results:[{id:$id,checkedAt:$now,expiresAt:($now+3600),services:{chatgpt:{state:"pass",network:"pass"}}}]}' > "$work/valid-cache"
    for cache_case in missing empty whitespace multiple null array scalar malformed wrong_results valid; do
        case "$cache_case" in
            missing) rm -f "$path";;
            empty) : > "$path";;
            whitespace) printf ' \n\t\n' > "$path";;
            multiple) cat "$work/valid-cache" "$work/valid-cache" > "$path";;
            null) printf 'null\n' > "$path";;
            array) printf '[]\n' > "$path";;
            scalar) printf '1\n' > "$path";;
            malformed) printf '{broken\n' > "$path";;
            wrong_results) printf '{"context":"fixture-context","results":{}}\n' > "$path";;
            valid) cp "$work/valid-cache" "$path";;
        esac
        policy="$(subscription_services_policy main)" || fail "invalid cache could not produce closed policy: $production $cache_case"
        printf '%s' "$policy" | jq -se 'length==1 and .[0].required==["chatgpt"] and (.[0].results|type)=="array"' >/dev/null || fail "configured requirement lost: $production $cache_case"
        subscription_source_policy '[]' '[]' "$work/items" auto '[]' '[]' '[]' "$policy" > "$work/filtered" || fail 'real source policy execution failed'
        if [ "$cache_case" = valid ]; then
            jq -e '.[0].runtimeEnabled==true and .[0].serviceExcluded==false' "$work/filtered" >/dev/null || fail "valid proof excluded: $production"
        else
            jq -e '.[0].runtimeEnabled==false and .[0].serviceExcluded==true' "$work/filtered" >/dev/null || fail "invalid cache bypassed admission: $production $cache_case"
        fi
    done
    for invalid_policy in '' ' ' 'null' '[]' '1' '{}' '{"required":[],"results":[]}{"required":[],"results":[]}'; do
        if subscription_source_policy '[]' '[]' "$work/items" auto '[]' '[]' '[]' "$invalid_policy" > "$work/filtered" 2>/dev/null; then
            fail "explicit invalid policy accepted: $production [$invalid_policy]"
        fi
        [ ! -s "$work/filtered" ] || fail 'invalid policy emitted partial admission output'
    done
    subscription_source_policy '[]' '[]' "$work/items" auto '[]' '[]' '[]' > "$work/filtered" || fail 'omitted optional services rejected'
    jq -e '.[0].runtimeEnabled==true and .[0].serviceExcluded==false' "$work/filtered" >/dev/null || fail 'omitted optional services changed policy'
done
printf 'PASS: service confirmation, service-list validation and models evidence reject empty/multiple JSON inputs with %s across every production copy\n' "$(jq --version)"

# Both retrofit paths must replace missing or misleading capability markers.
# The show_version-only wrapper keeps each disposable fixture off router code.
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
    version="${runtime#"$repo/openwrt/runtime-"}"; version="${version%%/*}"
    awk -v version="$version" 'NR==1 { print "#!/bin/sh"; print "if [ \"${1:-}\" = show_version ]; then echo \"" version "\"; exit 0; fi"; next } {print}' "$runtime" > "$work/current"
    for entry in sources apply-v2; do
        upgrade="$repo/openwrt/podkop-subscription-$entry-upgrade.sh"
        sed -n '/^service_guards_present() {$/,/^}$/p' "$upgrade" > "$work/capability"
        [ -s "$work/capability" ] || fail "service capability gate missing: $entry"
        . "$work/capability"
        service_guards_present "$work/current" || fail "current service capability rejected: $version $entry"
        # A stale guard in any individual function invalidates the full bundle.
        for function in subscription_services_confirm subscription_services_classify subscription_services_validate subscription_services_read subscription_services_policy subscription_source_policy; do
            awk -v name="$function" '
                index($0,name "() ")==1 {inside=1}
                inside {gsub("jq -se", "jq -e"); gsub("jq -cs", "jq -c")}
                {print}
                inside && ($0=="}" || $0==")") {inside=0}
            ' "$work/current" > "$work/partial"
            if service_guards_present "$work/partial"; then fail "partial guard admitted: $version $entry $function"; fi
        done
        for scenario in missing_marker stale_marker; do
            awk -v scenario="$scenario" '
                $0=="# subscription_jq16_service_guards_v1" && scenario=="missing_marker" {next}
                $0=="subscription_services_confirm() (" {inside=1}
                inside {gsub("jq -se", "jq -e")}
                {print}
                inside && $0==")" {inside=0}
            ' "$work/current" > "$work/target"
            chmod 755 "$work/target"
            cp "$work/target" "$work/before"
            rm -f "$work/backup"
            if [ "$entry" = sources ]; then
                PODKOP_SOURCES_TARGET="$work/target" PODKOP_SOURCES_SOURCE="$runtime" PODKOP_SOURCES_BACKUP="$work/backup" sh "$upgrade" > "$work/upgrade-log"
            else
                PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$work/target" PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$runtime" PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$work/backup" sh "$upgrade" > "$work/upgrade-log"
            fi
            ! grep -Fq 'already installed' "$work/upgrade-log" || fail "stale service guard skipped: $version $entry $scenario"
            cmp -s "$work/before" "$work/backup" || fail 'service retrofit lost original backup'
            service_guards_present "$work/target" || fail 'service retrofit omitted a guard'
            for block in subscription_services_v1 subscription_sources_v1; do
                sed -n "/^# $block begin$/,/^# $block end$/p" "$runtime" > "$work/expected"
                sed -n "/^# $block begin$/,/^# $block end$/p" "$work/target" > "$work/delivered"
                cmp -s "$work/expected" "$work/delivered" || fail "service retrofit delivered stale block: $block"
            done
            cp "$work/target" "$work/fixed"
            if [ "$entry" = sources ]; then
                PODKOP_SOURCES_TARGET="$work/target" PODKOP_SOURCES_SOURCE="$runtime" PODKOP_SOURCES_BACKUP="$work/backup" sh "$upgrade" > "$work/upgrade-log"
            else
                PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$work/target" PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$runtime" PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$work/backup" sh "$upgrade" > "$work/upgrade-log"
            fi
            grep -Fq 'already installed' "$work/upgrade-log" || fail 'fixed service retrofit retry was not a no-op'
            cmp -s "$work/fixed" "$work/target" || fail 'service retrofit retry changed runtime'
            cmp -s "$work/before" "$work/backup" || fail 'service retrofit retry changed backup'
        done
    done
done
printf 'PASS: both service retrofit paths replace missing/stale guards, preserve backups and retry without changes\n'
