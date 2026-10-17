# Opt-in per-section worker integration. No implicit global-reload fallback.
podkop_section_name() {
    local isolated
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
podkop_section_registry() {
    if podkop_section_single_mode; then
        jq -ce 'select(.mode=="single")|.sections|select(type=="array")' "$(podkop_section_root)/metadata.json"
        return $?
    fi
    jq -ce 'def valid_name: type=="string" and length>0 and all(explode[]; (.>=65 and .<=90) or (.>=97 and .<=122) or (.>=48 and .<=57) or .==95); select(.version==2) | .sections | select(type=="array" and length>0 and all(.[]; (.section|valid_name) and (.api_port|type=="number" and .>=1024 and .<=65535)) and (map(.section)|unique|length)==length)' "$(podkop_section_root)/metadata.json"
}
podkop_section_names() {
    local registry
    registry="$(podkop_section_registry)" || return 1
    printf '%s' "$registry" | jq -c 'map(.section)'
}
podkop_section_runtime_hash() {
    local root hashes file names section
    root="$(podkop_section_root)"
    names="$(podkop_section_names)" || return 1
    set -- "$1" "$root/logical.json" "$root/metadata.json"
    if ! podkop_section_single_mode; then
        for section in $(printf '%s' "$names" | jq -r '.[]'); do
            set -- "$@" "$root/workers/$section/worker.json"
        done
    fi
    for file in "$@"; do
        [ -s "$file" ] && [ ! -L "$file" ] || return 1
    done
    hashes="$(sha256sum "$@")" || return 1
    printf '%s\n' "$hashes" | sha256sum | awk '{print $1}'
}
podkop_section_ready() {
    local target="${1:-${PODKOP_SECTION_TARGET:-}}"
    podkop_section_manager status 2>/dev/null | jq -e --arg section "$target" 'if $section=="" then .ready==true else any(.sections[]?;.section==$section and .ready==true) end' >/dev/null
}
podkop_section_context_hash_legacy() {
    local isolated policy names
    names="$(podkop_section_names)" || return 1
    isolated="$(printf '%s' "$names" | jq -r 'join(",")')" || return 1
    policy="$(uci -q show podkop)" || return 1
    [ -n "$policy" ] || return 1
    # Hash private UCI text locally; never return credentials to the client.
    printf '%s\n' "$policy" | awk -v sections="$isolated" '
        BEGIN {n=split(sections,section,","); for(i=1;i<=n;i++) registered[section[i]]=1}
        /^podkop.settings.shutdown_correctly=/ {next}
        /^podkop\./ {
            split($0,parts,"."); name=parts[2]; sub(/=.*/,"",name)
            option=parts[3]; sub(/=.*/,"",option)
            if (!(name in registered)) {print; next}
            if (option ~ /^subscription_(excluded_link_ids|selected_link_ids|selection_mode|include_tags|exclude_tags|required_services|disabled_source_ids)$/) next
        }
        {print}' | sha256sum | awk '{print $1}'
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
    podkop_section_enabled || return 0
    isolated="$(printf '%s' "$1" | jq -er '.sections|select(type=="array" and length==1)|.[0].section|select(type=="string" and length>0 and all(explode[]; (.>=65 and .<=90) or (.>=97 and .<=122) or (.>=48 and .<=57) or .==95))')" || {
        PODKOP_SECTION_ERROR=isolated_section_only; return 1
    }
    if ! podkop_section_names | jq -e --arg section "$isolated" 'index($section)!=null' >/dev/null; then
        PODKOP_SECTION_ERROR=section_isolation_unavailable; return 1
    fi
    PODKOP_SECTION_TARGET="$isolated"
    if [ -n "$(uci -q changes podkop)" ]; then
        PODKOP_SECTION_ERROR=uci_pending_changes; return 1
    fi
    # Global saved intent is not applied by a section-only transaction.
    # Candidate and manager invariants prove DNS/routes/peers remain active.
    if ! podkop_section_ready "$isolated"; then PODKOP_SECTION_ERROR=section_isolation_unavailable; return 1; fi
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
podkop_section_prefer_live_candidate() (
    # Optional bounded startup hint, never a filter bypass or manual selection.
    local candidate="$1" section="$2" active api secret response leader delay temp
    active="$(podkop_section_root)/logical.json"
    api="$(jq -er '.experimental.clash_api.external_controller' "$active")" || exit 0
    secret="$(jq -r '.experimental.clash_api.secret//""' "$active")" || exit 0
    response="$(curl -q -fsS --max-time 2 -H "Authorization: Bearer $secret" "http://$api/proxies" 2>/dev/null)" || exit 0
    leader="$(printf '%s' "$response" | jq -er --arg s "$section" '
      select(.proxies[$s+"-out"].now==($s+"-urltest-out")) |
      .proxies[$s+"-urltest-out"].now | select(type=="string")')" || exit 0
    case "$leader" in "$section"-*-out) :;; *) exit 0;; esac
    delay="$(curl -q -fsS --max-time 3 -H "Authorization: Bearer $secret" "http://$api/proxies/$leader/delay?timeout=2000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" 2>/dev/null)" || exit 0
    printf '%s' "$delay" | jq -e '.delay|type=="number" and .>0' >/dev/null || exit 0
    temp="$candidate.live-order.$$"
    [ ! -e "$temp" ] && [ ! -L "$temp" ] || exit 1
    jq --slurpfile active "$active" --arg leader "$leader" --arg s "$section" '
      [$active[0].outbounds[]|select(.tag==$leader)|del(.tag)] as $old |
      [.outbounds[]|select(.type!="urltest" and .type!="selector")|
        select(($old|length)==1 and del(.tag)==$old[0])|.tag] as $matches |
      if ($matches|length)==1 then
        .outbounds |= map(if .tag==($s+"-urltest-out") and
          (.outbounds|index($matches[0]))!=null
          then .outbounds=([$matches[0]]+(.outbounds|map(select(.!=$matches[0])))) else . end)
      else . end' "$candidate" > "$temp" && mv "$temp" "$candidate" || { rm -f "$temp"; exit 1; }
)
podkop_section_candidate() (
    local isolated config
    isolated="${PODKOP_SECTION_TARGET:-}"
    [ -n "$isolated" ] || return 1
    config="$(jq -ce --arg section "$isolated" '
        def member: .==($section+"-out") or .==($section+"-urltest-out") or
          (startswith($section+"-") and endswith("-out") and
           (ltrimstr($section+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)));
        .outbounds |= map(select((.tag|member)|not))
        ' "$(podkop_section_root)/logical.json")" || return 1
    # Regenerate only this outbound pool. No DNS, route, nft or rule-set writes.
    PODKOP_SUBSCRIPTION_CACHE_ONLY=1 configure_outbound_handler "$isolated" || return 1
    printf '%s\n' "$config" | jq -e . > "$1" || return 1
    podkop_section_prefer_live_candidate "$1" "$isolated" || return 1
    podkop_section_candidate_validate "$1" "$isolated"
)
podkop_section_recover_snapshot() {
    local saved target root active
    root="$(podkop_section_root)"
    active="${PODKOP_SECTION_FRONTEND_CONFIG:-/etc/sing-box/config.json}"
    for saved in "${PODKOP_SECTION_RECOVERY_BASE:-/tmp}"/podkop-section-apply.*; do
        [ -d "$saved" ] && [ ! -L "$saved" ] && [ -f "$saved/recovery-target" ] || continue
        [ "$(stat -c %u "$saved")" = 0 ] && [ "$(stat -c %a "$saved")" = 700 ] || continue
        target="$(cat "$saved/recovery-target")"
        case "$target" in ''|*[!A-Za-z0-9_]*) continue;; esac
        cmp -s "$saved/candidate.json" "$root/logical.json" &&
        cmp -s "$saved/candidate.json" "$root/frontend.json" &&
        cmp -s "$saved/candidate.json" "$active" || continue
        podkop_section_ready "$target" || return 1
        # Commit validates the captured predecessor, local rules and live engine.
        # Never regenerate membership or bless a different concurrent graph.
        subscription_services_snapshot_section_commit "$target" "$saved" || return 1
        rm -f "$saved/recovery-target" || return 1
    done
}
podkop_section_apply() {
    local work result snapshot_staged=0
    PODKOP_SECTION_ERROR=''
    PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=1
    podkop_section_recover_snapshot || { PODKOP_SECTION_ERROR=section_snapshot_recovery_required; return 1; }
    work="$(mktemp -d /tmp/podkop-section-apply.XXXXXX)" || return 1
    chmod 700 "$work"
    cp "$(podkop_section_root)/logical.json" "$work/previous.json" || { rm -rf "$work"; return 1; }
    if ! podkop_section_candidate "$work/candidate.json"; then rm -rf "$work"; return 1; fi
    if [ "${PODKOP_SECTION_ROLLBACK:-0}" != 1 ] && command -v subscription_services_snapshot_save >/dev/null; then
        if ! command -v subscription_services_snapshot_section_stage >/dev/null ||
           ! command -v subscription_services_snapshot_section_commit >/dev/null ||
           ! subscription_services_snapshot_section_stage "$PODKOP_SECTION_TARGET" "$work"; then
            PODKOP_SECTION_ERROR=section_snapshot_preflight_failed
            rm -rf "$work"; return 1
        fi
        snapshot_staged=1
        printf '%s\n' "$PODKOP_SECTION_TARGET" > "$work/recovery-target" || return 1
    fi
    result=0
    PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=0
    podkop_section_manager apply "$work/candidate.json" "$PODKOP_SECTION_TARGET" > "$work/result" 2>&1 || result=$?
    [ "$result" -eq 0 ] || podkop_section_manager_error "$(cat "$work/result")"
    if [ "$result" -eq 0 ] && [ "$snapshot_staged" -eq 1 ]; then
        if ! subscription_services_snapshot_section_commit "$PODKOP_SECTION_TARGET" "$work"; then
            if ! podkop_section_manager apply "$work/previous.json" "$PODKOP_SECTION_TARGET" > "$work/rollback-result" 2>&1; then
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
    config_foreach podkop_section_collect section
    podkop_section_manager bootstrap "$1" "$PODKOP_SECTION_NAMES" >/dev/null || return 1
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
    local port registry
    registry="$(podkop_section_registry)" || return 1
    port="$(printf '%s' "$registry" | jq -er --arg tag "$1" '.[] | .section as $s | select($tag==($s+"-out") or $tag==($s+"-urltest-out") or ($tag|startswith($s+"-") and endswith("-out") and (ltrimstr($s+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)))) | .api_port')" || return 1
    printf 'http://127.0.0.1:%s' "$port"
}
podkop_section_api_merge() {
    if podkop_section_single_mode; then curl -fsS --max-time 5 --header "$2" "$1/proxies"; return $?; fi
    local main worker registry row section port
    main="$(curl -fsS --max-time 5 --header "$2" "$1/proxies")" || return 1
    registry="$(podkop_section_registry)" || return 1
    for row in $(printf '%s' "$registry" | jq -c '.[]'); do
        section="$(printf '%s' "$row" | jq -r '.section')"
        port="$(printf '%s' "$row" | jq -r '.api_port')"
        worker="$(curl -fsS --max-time 5 "http://127.0.0.1:$port/proxies")" || return 1
        main="$(printf '%s\n%s\n' "$main" "$worker" | jq -ces --arg section "$section" '
        def member: .==($section+"-out") or .==($section+"-urltest-out") or
          (startswith($section+"-") and endswith("-out") and
           (ltrimstr($section+"-")|rtrimstr("-out")|length>0 and all(explode[];.>=48 and .<=57)));
        select(length==2 and all(.[];.proxies|type=="object")) |
        .[0] as $base | .[1].proxies | with_entries(select(.key|member)) as $worker |
        $base | .proxies += $worker')" || return 1
    done
    printf '%s\n' "$main"
}
