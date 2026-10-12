# Opt-in single-section worker integration. No implicit global-reload fallback.
podkop_section_name() {
    local isolated
    if podkop_section_single_mode && [ -n "${PODKOP_SECTION_TARGET:-}" ]; then printf '%s' "$PODKOP_SECTION_TARGET"; return; fi
    config_get isolated settings subscription_isolated_section
    printf '%s' "$isolated"
}
podkop_section_single_mode() { [ "$(cat "$(podkop_section_root)/runtime-mode" 2>/dev/null)" = single ]; }
podkop_section_enabled() {
    podkop_section_single_mode && return 0
    if [ "${PODKOP_SECTION_MODE:-}" != split ] && [ ! -f "$(podkop_section_root)/metadata.json" ]; then return 0; fi
    [ -n "$(podkop_section_name)" ]
}
podkop_section_start_workers() {
    if podkop_section_single_mode; then
        "${PODKOP_SECTION_INIT:-/etc/init.d/podkop-section-worker}" stop || return 1
    else
        "${PODKOP_SECTION_INIT:-/etc/init.d/podkop-section-worker}" restart || return 1
        podkop_section_manager wait-ready || return 1
    fi
}
podkop_section_root() { printf '%s' "${PODKOP_SECTION_ROOT:-/etc/podkop/section-runtime}"; }
podkop_section_manager() { "${PODKOP_SECTION_MANAGER:-/usr/bin/podkop-section-runtime}" "$@"; }
podkop_section_manager_error() {
    case "$1" in
        'section_runtime: memory_floor'|'section_runtime: worker_count_memory_floor')
            PODKOP_SECTION_ERROR=section_memory_low; PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=1;;
        'section_runtime: memory_unavailable')
            PODKOP_SECTION_ERROR=section_memory_unavailable; PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=1;;
        *) PODKOP_SECTION_ERROR=section_runtime_failed;;
    esac
}
podkop_section_resource_preflight() {
    local result
    if result="$(podkop_section_manager preflight 2>&1)"; then return 0; fi
    podkop_section_manager_error "$result"
    return 1
}
podkop_section_runtime_hash() {
    local root hashes file
    root="$(podkop_section_root)"
    if podkop_section_single_mode; then
        for file in "$1" "$root/logical.json" "$root/metadata.json"; do [ -s "$file" ] && [ ! -L "$file" ] || return 1; done
        sha256sum "$1" "$root/logical.json" "$root/metadata.json" | sha256sum | awk '{print $1}'
        return $?
    fi
    for file in "$1" "$root/worker.json" "$root/logical.json"; do
        [ -s "$file" ] && [ ! -L "$file" ] || return 1
    done
    hashes="$(sha256sum "$1" "$root/worker.json" "$root/logical.json")" || return 1
    printf '%s\n' "$hashes" | sha256sum | awk '{print $1}'
}
podkop_section_ready() {
    if podkop_section_single_mode; then
        podkop_section_manager status 2>/dev/null | jq -e --arg section "${PODKOP_SECTION_TARGET:-}" 'if $section=="" then .ready==true else any(.sections[]?;.section==$section and .ready==true) end' >/dev/null
        return $?
    fi
    /usr/bin/podkop-section-runtime status 2>/dev/null | jq -e --arg section "$(podkop_section_name)" '.ready==true and .section==$section' >/dev/null
}
podkop_section_context_hash_legacy() {
    local isolated policy
    isolated="$(podkop_section_name)"
    policy="$(uci -q show podkop)" || return 1
    [ -n "$policy" ] || return 1
    # Hash private UCI text locally; never return credentials to the client.
    printf '%s\n' "$policy" | awk -v prefix="podkop.$isolated." '
        /^podkop.settings.shutdown_correctly=/ {next}
        index($0,prefix)==1 {
            option=substr($0,length(prefix)+1); sub(/=.*/,"",option)
            if (option ~ /^subscription_(excluded_link_ids|selected_link_ids|selection_mode|include_tags|exclude_tags|required_services|disabled_source_ids)$/) next
        }
        {print}' | sha256sum | awk '{print $1}'
}
podkop_section_names() {
    if podkop_section_single_mode; then
        jq -ce 'select(.mode=="single")|[.sections[].section]' "$(podkop_section_root)/metadata.json"
    else jq -cn --arg section "$(podkop_section_name)" '[$section]'; fi
}
podkop_section_context_hash() {
    local names policy
    names="$(podkop_section_names)" || return 1
    # Read the same UCI view as LuCI. Preflight rejects staged changes first.
    # Keep unknown options and section/list order: only documented non-runtime
    # controls are omitted, never a broad dns_* or subscription_* prefix.
    policy="$(ubus -S call uci get '{"config":"podkop"}')" || return 1
    policy="$(printf '%s' "$policy" | jq -ceS --argjson registered "$names" '
      .values | select(type=="object" and (.settings|type=="object")) |
      .settings.enable_utls_fallback //= "0" |
      .settings.dns_failover_enabled //= "0" |
      .settings.dns_failover_active_slot //= "primary" |
      del(.settings.shutdown_correctly,
          .settings.dns_optimizer_candidates,.settings.dns_optimizer_bootstrap_candidates,
          .settings.dns_optimizer_protocols,.settings.dns_optimizer_bootstrap_protocols,
          .settings.dns_optimizer_custom_doh,.settings.dns_optimizer_custom_dot,
          .settings.dns_optimizer_custom_udp,.settings.dns_optimizer_custom_tcp,
          .settings.dns_optimizer_include_current,.settings.dns_optimizer_include_wan,
          .settings.dns_failover_check_interval,.settings.dns_failover_failure_threshold) |
      if .settings.dns_failover_enabled!="1" or .settings.dns_failover_active_slot!="secondary"
      then del(.settings.secondary_dns_type,.settings.secondary_dns_server,
               .settings.secondary_bootstrap_dns_type,.settings.secondary_bootstrap_dns_server)
      else . end |
      with_entries(if (.key as $key | $registered | index($key))!=null
        then .value |= del(.subscription_excluded_link_ids,.subscription_selected_link_ids,
          .subscription_selection_mode,.subscription_include_tags,.subscription_exclude_tags,
          .subscription_required_services,.subscription_disabled_source_ids)
        else . end)')" || return 1
    [ -n "$policy" ] || return 1
    printf 'v2:'
    printf '%s\n' "$policy" | sha256sum | awk '{print $1}'
}
podkop_section_context_matches() {
    local expected actual changes
    changes="$(uci -q changes podkop)" || return 1
    [ -z "$changes" ] || return 1
    expected="$(cat "$(podkop_section_root)/context.sha256" 2>/dev/null)" || return 1
    [ -n "$expected" ] || return 1
    case "$expected" in
        v2:*) actual="$(podkop_section_context_hash)" || return 1;;
        *) actual="$(podkop_section_context_hash_legacy)" || return 1;;
    esac
    [ "$expected" = "$actual" ]
}
podkop_section_preflight() {
    local isolated
    PODKOP_SECTION_ERROR=''
    PODKOP_SECTION_TARGET=''
    if podkop_section_single_mode; then
        isolated="$(printf '%s' "$1" | jq -er '.sections|select(type=="array" and length==1)|.[0].section|select(type=="string" and length>0 and all(explode[];(.>=65 and .<=90) or (.>=97 and .<=122) or (.>=48 and .<=57) or .==95))')" || { PODKOP_SECTION_ERROR=isolated_section_only; return 1; }
        podkop_section_names | jq -e --arg s "$isolated" 'index($s)!=null' >/dev/null || { PODKOP_SECTION_ERROR=section_isolation_unavailable; return 1; }
        PODKOP_SECTION_TARGET="$isolated"
    fi
    isolated="$(podkop_section_name)"
    [ -n "$isolated" ] || return 0
    PODKOP_SECTION_TARGET="$isolated"
    case "$isolated" in *[!A-Za-z0-9_]*|'') PODKOP_SECTION_ERROR=section_isolation_unavailable; return 1;; esac
    if ! printf '%s' "$1" | jq -e --arg section "$isolated" '.sections|length==1 and .[0].section==$section' >/dev/null 2>&1; then
        PODKOP_SECTION_ERROR=isolated_section_only; return 1
    fi
    if [ -n "$(uci -q changes podkop)" ]; then
        PODKOP_SECTION_ERROR=uci_pending_changes; return 1
    fi
    # Global saved intent is not applied by a section-only transaction.
    # Candidate and manager invariants prove DNS/routes/peers remain active.
    if ! podkop_section_ready; then PODKOP_SECTION_ERROR=section_isolation_unavailable; return 1; fi
    podkop_section_resource_preflight || return 1
}
podkop_section_candidate_validate() {
    local before after
    before="$(jq -ceS --arg section "$2" '
      def member: .==($section+"-out") or .==($section+"-urltest-out") or
        (startswith($section+"-") and endswith("-out") and
         (ltrimstr($section+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)));
      .outbounds |= map(select((.tag|member)|not))' "$(podkop_section_root)/logical.json")" || return 1
    after="$(jq -ceS --arg section "$2" '
      def member: .==($section+"-out") or .==($section+"-urltest-out") or
        (startswith($section+"-") and endswith("-out") and
         (ltrimstr($section+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)));
      .outbounds |= map(select((.tag|member)|not))' "$1")" || return 1
    [ "$before" = "$after" ]
}
podkop_section_candidate() (
    local isolated config
    isolated="$(podkop_section_name)"
    config="$(jq -ce --arg section "$isolated" '
        def member: .==($section+"-out") or .==($section+"-urltest-out") or
          (startswith($section+"-") and endswith("-out") and
           (ltrimstr($section+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)));
        .outbounds |= map(select((.tag|member)|not))
        ' "$(podkop_section_root)/logical.json")" || return 1
    # Regenerate only this outbound pool. No DNS, route, nft or rule-set writes.
    PODKOP_SUBSCRIPTION_CACHE_ONLY=1 configure_outbound_handler "$isolated" || return 1
    printf '%s\n' "$config" | jq -e . > "$1" || return 1
    podkop_section_candidate_validate "$1" "$isolated"
)
podkop_section_apply() {
    local work result snapshot_staged=0
    PODKOP_SECTION_ERROR=''
    PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=1
    work="$(mktemp -d /tmp/podkop-section-apply.XXXXXX)" || return 1
    chmod 700 "$work"
    cp "$(podkop_section_root)/logical.json" "$work/previous.json" || { rm -rf "$work"; return 1; }
    if ! podkop_section_candidate "$work/candidate.json"; then rm -rf "$work"; return 1; fi
    if [ "${PODKOP_SECTION_ROLLBACK:-0}" != 1 ] && command -v subscription_services_snapshot_save >/dev/null; then
        if ! command -v subscription_services_snapshot_section_stage >/dev/null ||
           ! command -v subscription_services_snapshot_section_commit >/dev/null ||
           ! subscription_services_snapshot_section_stage "$(podkop_section_name)" "$work"; then
            rm -rf "$work"; return 1
        fi
        snapshot_staged=1
    fi
    result=0
    PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=0
    podkop_section_manager apply "$work/candidate.json" "$(podkop_section_name)" > "$work/result" 2>&1 || result=$?
    [ "$result" -eq 0 ] || podkop_section_manager_error "$(cat "$work/result")"
    if [ "$result" -eq 0 ] && [ "$snapshot_staged" -eq 1 ]; then
        if ! subscription_services_snapshot_section_commit "$(podkop_section_name)" "$work"; then
            if ! podkop_section_manager apply "$work/previous.json" "$(podkop_section_name)" > "$work/rollback-result" 2>&1; then
                PODKOP_SECTION_ERROR=section_snapshot_rollback_failed
                printf '%s\n' 'section_runtime: snapshot_rollback_failed' >&2
            fi
            result=1
        fi
    fi
    rm -rf "$work"
    return "$result"
}
podkop_section_collect() {
    local type mode
    config_get type "$1" connection_type
    config_get mode "$1" proxy_config_type
    [ "$type:$mode" = proxy:subscription_urltest ] || return 0
    section_has_subscription_urls "$1" || return 0
    PODKOP_SECTION_NAMES="$(printf '%s' "$PODKOP_SECTION_NAMES" | jq -c --arg s "$1" '.+[$s]')"
}
podkop_section_bootstrap() {
    local PODKOP_SECTION_NAMES='[]'
    if podkop_section_single_mode || [ ! -f "$(podkop_section_root)/metadata.json" ]; then
        config_foreach podkop_section_collect section
        podkop_section_manager bootstrap "$1" "$PODKOP_SECTION_NAMES" >/dev/null || return 1
    else
        podkop_section_manager bootstrap "$1" "$(podkop_section_name)" >/dev/null || return 1
    fi
    podkop_section_context_hash > "$(podkop_section_root)/context.sha256" || return 1
    cp "$(podkop_section_root)/frontend.json" "$1"
}
podkop_section_logical_path() {
    if podkop_section_enabled; then printf '%s/logical.json' "$(podkop_section_root)";
    else printf '%s' /etc/sing-box/config.json; fi
}
podkop_section_api_url() {
    # Keep native URL and authentication in the caller for the single engine.
    podkop_section_single_mode && return 1
    local isolated
    isolated="$(podkop_section_name)"
    [ -n "$isolated" ] || return 1
    case "$1" in "$isolated-out"|"$isolated-urltest-out") ;;
        *) printf '%s' "$1" | grep -Eq "^${isolated}-[0-9]+-out$" || return 1;;
    esac
    printf '%s' http://127.0.0.1:19163
}
podkop_section_api_merge() {
    if podkop_section_single_mode; then curl -fsS --max-time 5 --header "$2" "$1/proxies"; return $?; fi
    local main worker
    main="$(curl -fsS --max-time 5 --header "$2" "$1/proxies")" || return 1
    worker="$(curl -fsS --max-time 5 http://127.0.0.1:19163/proxies)" || return 1
    printf '%s\n%s\n' "$main" "$worker" | jq -es --arg section "$(podkop_section_name)" '
        def member: .==($section+"-out") or .==($section+"-urltest-out") or
          (startswith($section+"-") and endswith("-out") and
           (ltrimstr($section+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)));
        select(length==2 and all(.[];.proxies|type=="object")) |
        .[0] as $base | .[1].proxies | with_entries(select(.key|member)) as $worker |
        $base | .proxies += $worker'
}
