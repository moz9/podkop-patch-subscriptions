# subscription_services_v1 begin
# Public website diagnostics only: no API keys, cookies or production selectors.
subscription_services_catalog() {
    printf '%s\n' '[{"id":"gemini","label":"Gemini Web","proof":"preliminary_or_manual"},{"id":"chatgpt","label":"ChatGPT Web","proof":"preliminary_or_manual"}]'
}

subscription_services_validate() {
    printf '%s' "$1" | jq -e 'type=="array" and length<=2 and all(.[]; .=="gemini" or .=="chatgpt") and length==(unique|length)' >/dev/null 2>&1
}

subscription_required_services_json() {
    local values
    values="$(subscription_tags_json "$1" subscription_required_services)" || return 1
    subscription_services_validate "$values" || return 1
    printf '%s\n' "$values"
}

subscription_services_context() {
    local udp='' dns settings
    config_get udp "$1" enable_udp_over_tcp
    # DNS/profile changes invalidate observations, but changing the working selector does not.
    dns="$(jq -ceS '.dns | select(type=="object" and (.servers|type=="array"))' /etc/sing-box/config.json)" || return 1
    settings="$(uci -q show podkop.settings)" || return 1
    # Bind desired DNS settings too, so edits before a runtime rebuild cannot reuse old checks.
    settings="$(printf '%s\n' "$settings" | sed '/^podkop.settings.shutdown_correctly=/d' | LC_ALL=C sort)"
    { printf '%s\n' "$dns" "$settings"; printf '%s\n' "service-web-v1:$udp"; } | sha256sum | awk '{print $1}'
}

subscription_services_cache_path() {
    printf '%s/%s.json\n' "${PODKOP_SERVICE_CACHE_DIR:-/etc/podkop/subscriptions/service-checks}" "$1"
}

subscription_services_read() {
    local section="$1" context now path
    context="$(subscription_services_context "$section")" || return 1
    [ -n "$context" ] || return 1
    now="$(date +%s)"; path="$(subscription_services_cache_path "$section")"
    if [ -s "$path" ] && [ "$(wc -c < "$path")" -le 2097152 ]; then
        jq -c --arg context "$context" --argjson now "$now" '
            if .context==$context then [.results[]? | select(
                (.checkedAt|type=="number") and .checkedAt>0 and .checkedAt<=$now
                and (.expiresAt|type=="number") and .expiresAt>$now and .expiresAt<=(.checkedAt+86400))] else [] end
        ' "$path" 2>/dev/null || printf '[]\n'
    else printf '[]\n'; fi
}

subscription_services_policy() {
    local required results
    required="${2:-}"
    [ -n "$required" ] || required="$(subscription_required_services_json "$1")" || return 1
    subscription_services_validate "$required" || return 1
    if [ "$required" = '[]' ]; then results='[]'; else results="$(subscription_services_read "$1")" || return 1; fi
    printf '%s\n' "$results" | jq -c --argjson required "$required" '{required:$required,results:.}'
}

get_subscription_services() {
    local section="$1" required results
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || { subscription_services_error invalid_section; return 1; }
    required="$(subscription_required_services_json "$section")" || { subscription_services_error invalid_required_services; return 1; }
    results="$(subscription_services_read "$section")" || { subscription_services_error context_unavailable; return 1; }
    printf '%s\n' "$results" | jq -c --argjson required "$required" --argjson catalog "$(subscription_services_catalog)" \
        '{success:true,requiredServices:$required,catalog:$catalog,results:.,ttl:86400,capacity:2048}'
}

subscription_services_error() {
    jq -cn --arg error "$1" '{success:false,error:$error}'
}

subscription_services_store() {
    local section="$1" id="$2" services="$3" context now path dir
    validate_subscription_section_name "$section" && validate_subscription_link_id "$id" || return 1
    context="$(subscription_services_context "$section")" || return 1
    [ -n "$context" ] || return 1
    now="$(date +%s)"; path="$(subscription_services_cache_path "$section")"; dir="${path%/*}"
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir" || return 1
    # Keep bounded expired observations for exact already-admitted boot snapshot identity.
    # The admission reader still rejects their expiry; this never renews old proof.
    if [ -s "$path" ] && [ "$(wc -c < "$path")" -le 2097152 ]; then
        cat "$path"
    else printf '{}\n'; fi | jq -c --arg context "$context" --arg id "$id" --argjson now "$now" --argjson services "$services" '
    # At most 2048 observations / 2 MiB per section; only public state and opaque IDs.
        (if .context==$context then .results else [] end) as $previous
        |
        {context:$context,results:(($previous|map(select(.id!=$id))) + [{id:$id,checkedAt:$now,expiresAt:($now+86400),services:$services}] | .[-2048:])}
    ' > "$path.tmp.$$" || return 1
    if [ ! -s "$path.tmp.$$" ] || [ "$(wc -c < "$path.tmp.$$")" -gt 2097152 ]; then rm -f "$path.tmp.$$"; return 1; fi
    chmod 600 "$path.tmp.$$" && mv "$path.tmp.$$" "$path"
}

subscription_services_classify() {
    local service="$1" rc="$2" code="$3" body="$4" state=unknown network=pass reason=confirmation_required
    case "$service" in gemini|chatgpt) ;; *) return 1;; esac
    case "$code" in 2??) ;; 401|403|404|429) state=unknown; reason=challenge_required;; *) network=fail; state=fail; reason=http_failed;; esac
    if [ "$rc" -ne 0 ]; then network=fail; state=fail; reason=network_failed; fi
    if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
        if [ "$service" = gemini ] && printf '%s' "$body" | grep -Eiq '<html|<!doctype html' && printf '%s' "$body" | grep -iq 'Gemini' && printf '%s' "$body" | grep -Fq '45631641,null,true'; then
            state=pass; reason=region_precheck_passed
        elif [ "$service" = chatgpt ] && printf '%s' "$body" | jq -e 'type=="object" and (.models|type=="array" and length>0 and all(.[]; type=="object" and ((.slug // .id)|type=="string" and length>0)))' >/dev/null 2>&1; then
            state=pass; reason=anonymous_models_available
        fi
    fi
    if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -Eiq 'unusual traffic|captcha|cf-chl-|access denied'; then
        state=unknown; reason=challenge_required
    fi
    if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -Eiq 'not (available|supported) in (your|this) (country|region)|unsupported[ _](country|region)'; then
        state=fail; network=fail; reason=region_denied
    fi
    jq -cn --arg state "$state" --arg network "$network" --arg reason "$reason" --arg code "$code" \
        '{state:$state,network:$network,reason:$reason,httpCode:($code|tonumber? // 0),manual:false}'
}

subscription_services_probe() {
    local section="$1" id="$2" services="$3" proxy="$4" work="$5" service url rc code value results='{}' failed=0
    printf '%s' "$services" | jq -r '.[]' > "$work/services.list" || return 1
    while IFS= read -r service; do
        if [ "$failed" = 1 ]; then
            value='{"state":"unknown","network":"fail","reason":"skipped_after_failure","httpCode":0,"manual":false}'
            results="$(printf '%s' "$results" | jq -c --arg service "$service" --argjson value "$value" '.[$service]=$value')" || return 1
            continue
        fi
        case "$service" in
            gemini) url=https://gemini.google.com/;;
            chatgpt) url=https://chatgpt.com/backend-anon/models;;
            *) return 1;;
        esac
        # TLS remains verified. Redirects restricted to HTTPS; bodies are temporary/private.
        rc=0
        curl -sS -L --proto '=https' --proto-redir '=https' --max-redirs 3 --proxy "$proxy" --noproxy '' \
            -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36' -H 'Accept-Language: en-US,en;q=0.9' \
            --connect-timeout 2 -m 4 --retry 0 --max-filesize 1048576 -o "$work/service.body" -w '%{http_code}' "$url" > "$work/service.code" 2>"$work/service.error" &
        curl_pids=$!; wait "$curl_pids" || rc=$?; curl_pids=''
        code="$(cat "$work/service.code")"
        value="$(subscription_services_classify "$service" "$rc" "$code" "$(head -c 1048576 "$work/service.body" 2>/dev/null)")" || return 1
        if printf '%s' "$value" | jq -e '.state=="fail"' >/dev/null; then failed=1; fi
        results="$(printf '%s' "$results" | jq -c --arg service "$service" --argjson value "$value" '.[$service]=$value')" || return 1
    done < "$work/services.list"
    subscription_services_store "$section" "$id" "$results" || return 1
    jq -cn --arg id "$id" --argjson services "$results" '{success:true,id:$id,services:$services}'
}

subscription_services_check() {
    subscription_services_validate "${3:-}" && [ "$3" != '[]' ] || { subscription_services_error invalid_services; return 1; }
    subscription_isolated_test "$1" "$2" services "$3"
}

subscription_services_confirm() (
    section="$1"; id="$2"; service="$3"; enabled="$4"; locked=0
    trap '[ "$locked" = 0 ] || subscription_action_lock_release' EXIT
    trap 'exit 130' INT TERM HUP
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || { subscription_services_error invalid_section; exit 1; }
    validate_subscription_link_id "$id" || { subscription_services_error invalid_link_id; exit 1; }
    case "$service:$enabled" in gemini:true|chatgpt:true|gemini:false|chatgpt:false) ;; *) subscription_services_error invalid_confirmation; exit 1;; esac
    subscription_runtime_busy && { subscription_services_error service_busy; exit 1; }
    subscription_action_lock_acquire service_confirmation || { subscription_services_error service_busy; exit 1; }; locked=1
    jq -e --arg id "$id" 'any(.[]; .id==$id and .supported)' "$(get_subscription_items_cache_path "$section")" >/dev/null 2>&1 || { subscription_services_error subscription_link_not_available; exit 1; }
    results="$(subscription_services_read "$section")" || exit 1
    row="$(printf '%s' "$results" | jq -c --arg id "$id" '.[] | select(.id==$id)')"
    printf '%s' "$row" | jq -e --arg service "$service" '.services[$service].network=="pass"' >/dev/null 2>&1 || { subscription_services_error recent_network_check_required; exit 1; }
    if [ "$enabled" = true ] && ! printf '%s' "$row" | jq -e --arg service "$service" '.services[$service].state=="unknown"' >/dev/null; then
        subscription_services_error confirmation_requires_unknown_state
        exit 1
    fi
    # Confirmation cannot extend the underlying network observation's expiry.
    path="$(subscription_services_cache_path "$section")"
    jq --arg id "$id" --arg service "$service" --argjson enabled "$enabled" '
        .results |= map(if .id==$id then .services[$service] |= (.state=(if $enabled then "pass" else "fail" end) | .manual=true | .reason="user_confirmed") else . end)
    ' "$path" > "$path.tmp.$$" && chmod 600 "$path.tmp.$$" && mv "$path.tmp.$$" "$path" || exit 1
    jq -cn --arg id "$id" --arg service "$service" --argjson enabled "$enabled" '{success:true,id:$id,service:$service,confirmed:$enabled}'
)

# Fail before stopping an existing daemon. Expiry does not trigger a background apply.
subscription_services_preflight_section() {
    local section="$1" required work items all disabled excluded
    validate_subscription_urltest_section "$section" || return 0
    required="$(subscription_required_services_json "$section")" || { SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1; return 0; }
    [ "$required" != '[]' ] || return 0
    work="$(mktemp -d)" || { SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1; return 0; }
    if command -v collect_urltest_proxy_links >/dev/null 2>&1 && collect_urltest_proxy_links "$section" "$work/manual" && [ -s "$work/manual" ]; then
        SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1
        rm -rf "$work"; return 0
    fi
    items="$(get_subscription_items_cache_path "$section")"; all="$(get_subscription_all_cache_path "$section")"
    disabled="$(subscription_disabled_sources_json "$section")"
    excluded='[]'
    if command -v collect_subscription_excluded_ids >/dev/null 2>&1; then
        collect_subscription_excluded_ids "$section" "$work/excluded"
        excluded="$(jq -Rsc 'split("\n") | map(select(length>0))' "$work/excluded")"
    fi
    if ! cp "$items" "$work/items" || ! subscription_filter_source_links "$work/items" "$all" "$work/links" "$disabled" "$excluded" "$section" || [ ! -s "$work/links" ]; then
        SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1
    fi
    rm -rf "$work"
}

subscription_services_preflight() {
    SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=0
    config_foreach subscription_services_preflight_section section
    if [ "$SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED" != 0 ]; then
        log 'Required-service evidence is unavailable or expired; retaining the working runtime' warn
        return 1
    fi
}
# subscription_services_v1 end
