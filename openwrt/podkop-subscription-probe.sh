# subscription_isolated_probe_v1 begin
# Diagnostics use a private loopback listener and never the working selector.
# subscription_probe_context_v2
# subscription_probe_diagnostics_v1
# subscription_light_probe_v1
subscription_probe_diagnostic() (
    # One bounded record per validated section in tmpfs. No configs, links,
    # response bodies, or arbitrary stderr which may contain secrets.
    section="$1"; id="$2"; stage="$3"; error="$4"; success="$5"
    validate_subscription_section_name "$section" && validate_subscription_link_id "$id" || exit 0
    dir="${PODKOP_PROBE_STATUS_DIR:-/tmp/podkop-service-probe-status}"
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir" || exit 0
    jq -cn --arg section "$section" --arg id "$id" --arg stage "$stage" --arg error "$error" --argjson success "$success" --argjson timestamp "$(date +%s)" \
        '{success:$success,section:$section,id:$id,stage:$stage,error:$error,timestamp:$timestamp}' > "$dir/$section.json.tmp.$$" || exit 0
    chmod 600 "$dir/$section.json.tmp.$$" && mv "$dir/$section.json.tmp.$$" "$dir/$section.json" || rm -f "$dir/$section.json.tmp.$$"
)

subscription_probe_config() {
    # Keep real resolvers and their detours. LAN FakeIP/routing lists do not
    # serve this private HTTP CONNECT listener and must not download per node.
    printf '%s\n' "$1" | jq -ce --arg tag "$2" --argjson port "$3" '
        def refs:
            [.. | objects | (.detour? // empty), (.download_detour? // empty), (.outbounds[]?)]
            | map(select(type=="string" and length>0)) | unique;
        def closure($nodes; $seen):
            ([$seen[] as $ref | ($nodes[$ref] // error("missing_probe_dependency")) | refs[]] + $seen | unique) as $next
            | if $next==$seen then $seen else closure($nodes; $next) end;
        select(any(.outbounds[]; .tag==$tag))
        | if (.outbounds|map(.tag)|unique|length)!=(.outbounds|length)
             then error("duplicate_probe_tag") else . end
        | [.dns.servers[]? | select(.type=="fakeip") | .tag] as $fake
        | .dns.rules=((.dns.rules//[]) | map(select(.server as $server | ($fake|index($server))==null)))
        | [.dns.rules[]? | .. | objects | .rule_set? // empty | if type=="array" then .[] else . end] as $dns_sets
        | .inbounds=[{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:$port}]
        | .route.rules=[{inbound:["probe-in"],outbound:$tag}]
        | .route.rule_set=((.route.rule_set//[]) | map(select(.tag as $set | ($dns_sets|index($set))!=null)))
        # Only the candidate and real DNS/dial dependencies may start sockets.
        # An unrelated urltest pool must not load every subscription node.
        | ((.outbounds//[])+(.endpoints//[]) | map({key:.tag,value:.}) | from_entries) as $nodes
        | ([$tag] + (.dns|refs) + (.route.rule_set|refs) | unique) as $roots
        | closure($nodes; $roots) as $reachable
        | .outbounds|=map(select(.tag as $ref | ($reachable|index($ref))!=null))
        | if has("endpoints") then .endpoints|=map(select(.tag as $ref | ($reachable|index($ref))!=null)) else . end
        | .route.final=$tag | .route.default_mark=2097152
        | .outbounds|=map(if .type=="urltest" then
            {type:"selector",tag:.tag,outbounds:.outbounds,default:.outbounds[0]}
            else . end)
        # PE TLS fallback is part of the selected dial policy, unlike shared
        # controller/cache state. Preserve the already capability-gated policy.
        | if .experimental.utls_fallback? != null then
            .experimental={utls_fallback:.experimental.utls_fallback}
          else del(.experimental) end
        | .log={level:"warn"}'
}

subscription_probe_resources() {
    # 16 MiB for the working services plus 16 MiB for the private check/run.
    # Refuse unknown RAM; swap is not a safe launch budget on these routers.
    local mode="$1" requested="${2:-1}" active="${3:-0}" total available
    SUBSCRIPTION_PROBE_ERROR=''
    SUBSCRIPTION_PROBE_STREAMS="$requested"
    SUBSCRIPTION_PROBE_REQUIRED_KB=32768
    # Once the child is resident, protect the live floor without reserving its
    # own launch budget twice. Curl streams still need their separate reserve.
    [ "$active" = 0 ] || SUBSCRIPTION_PROBE_REQUIRED_KB=16384
    total="$(awk '/^MemTotal:/ {print $2; exit}' "${PODKOP_SUBSCRIPTION_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null)" || total=''
    available="$(awk '/^MemAvailable:/ {print $2; exit}' "${PODKOP_SUBSCRIPTION_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null)" || available=''
    case "$total:$available" in *[!0-9:]*|:*|*:) SUBSCRIPTION_PROBE_ERROR=memory_unavailable; return 1;; esac
    if [ "$mode" = speed ]; then
        if [ "$total" -le 262144 ] && [ "$requested" -gt 2 ]; then SUBSCRIPTION_PROBE_STREAMS=2; fi
        SUBSCRIPTION_PROBE_REQUIRED_KB=$((SUBSCRIPTION_PROBE_REQUIRED_KB + SUBSCRIPTION_PROBE_STREAMS * 2048))
    fi
    [ "$available" -ge "$SUBSCRIPTION_PROBE_REQUIRED_KB" ] || { SUBSCRIPTION_PROBE_ERROR=insufficient_memory; return 1; }
}

subscription_isolated_test() {
    local isolated_worker_pid isolated_worker_rc isolated_worker_traps
    isolated_worker_traps="$(trap)"
    (
    section="$1"
    item_id="$2"
    mode="${3:-ping}"
    probe_pid=""
    curl_pids=""
    work=""
    locked=0
    probe_stage=validation
    SUBSCRIPTION_PROBE_ERROR=''
    cleanup_probe() {
        for child in $curl_pids; do kill "$child" 2>/dev/null || true; done
        if [ -n "$probe_pid" ]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi
        [ -z "$work" ] || rm -rf "$work"
        [ "$locked" -eq 0 ] || subscription_action_lock_release
    }
    trap cleanup_probe EXIT
    trap 'exit 130' INT TERM HUP
    probe_error() {
        [ "$mode" != services ] || subscription_probe_diagnostic "$section" "$item_id" "$probe_stage" "$1" false
        jq -cn --arg error "$1" --arg id "$item_id" --arg section "$section" --arg stage "$probe_stage" --argjson timestamp "$(date +%s)" \
            '{success:false,error:$error,id:$id,section:$section,stage:$stage,timestamp:$timestamp}'
        exit 1
    }
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || probe_error invalid_section
    validate_subscription_link_id "$item_id" || probe_error invalid_link_id
    case "$mode" in ping|speed) ;; services) subscription_services_validate "${4:-}" || probe_error invalid_services;; *) probe_error invalid_probe_mode ;; esac
    probe_stage=action_lock
    subscription_runtime_busy && probe_error service_busy
    subscription_action_lock_acquire "isolated_$mode" || probe_error service_busy
    locked=1
    streams=1
    requested_streams=1
    if [ "$mode" = speed ]; then
        bytes="$(get_subscription_benchmark_bytes)"
        requested_streams="$(get_subscription_benchmark_streams)"
        timeout="$(get_subscription_benchmark_timeout)"
        case "$bytes:$requested_streams:$timeout" in *[!0-9:]*|'') probe_error invalid_benchmark_options ;; esac
        [ "$requested_streams" -ge 1 ] && [ "$requested_streams" -le 8 ] && [ "$timeout" -ge 1 ] && [ "$timeout" -le 60 ] && [ "$bytes" -ge 65536 ] || probe_error invalid_benchmark_options
    fi
    probe_stage=memory_admission
    subscription_probe_resources "$mode" "$requested_streams" || probe_error "$SUBSCRIPTION_PROBE_ERROR"
    streams="$SUBSCRIPTION_PROBE_STREAMS"
    probe_stage=temporary_directory
    umask 077
    work="$(mktemp -d /tmp/podkop-subscription-probe.XXXXXX)" || probe_error temporary_directory_failed
    probe_stage=subscription_identity
    items="$(get_subscription_items_cache_path "$section")"
    jq -e --arg id "$item_id" 'any(.[]; .id == $id and .supported == true)' "$items" >/dev/null 2>&1 || probe_error subscription_link_not_available
    link=""
    while IFS= read -r candidate || [ -n "$candidate" ]; do
        if [ "$(get_subscription_link_id "$candidate")" = "$item_id" ]; then link="$candidate"; break; fi
    done < "$(get_subscription_all_cache_path "$section")"
    [ -n "$link" ] || probe_error subscription_link_not_available
    name="$(jq -r --arg id "$item_id" '.[] | select(.id == $id) | .name' "$items")"
    probe_stage=dns_config
    config="$(jq -ce 'select(.dns|type=="object")' "$(if command -v podkop_section_logical_path >/dev/null; then podkop_section_logical_path; else echo /etc/sing-box/config.json; fi)")" || probe_error dns_config_invalid
    config_get udp_over_tcp "$section" enable_udp_over_tcp
    probe_stage=config_parse
    config="$(sing_box_cf_add_proxy_outbound "$config" subscription-probe "$link" "$udp_over_tcp" 2>"$work/parser.log")" || probe_error invalid_config
    tag="$(get_outbound_tag_by_section subscription-probe)"
    port=$((43000 + $$ % 1000))
    tries=0
    while netstat -ln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1)); tries=$((tries + 1))
        [ "$tries" -lt 20 ] || probe_error probe_port_busy
    done
    probe_stage=config_build
    subscription_probe_config "$config" "$tag" "$port" > "$work/config.json" || probe_error invalid_config
    # The full source/parser strings are no longer needed by the child.
    config=''
    probe_stage=memory_admission
    subscription_probe_resources "$mode" "$streams" || probe_error "$SUBSCRIPTION_PROBE_ERROR"
    probe_stage=config_check
    sing-box check -c "$work/config.json" >"$work/check.log" 2>&1 || probe_error invalid_config
    probe_stage=memory_admission
    subscription_probe_resources "$mode" "$streams" || probe_error "$SUBSCRIPTION_PROBE_ERROR"
    probe_stage=listener_start
    sing-box run -c "$work/config.json" >"$work/runtime.log" 2>&1 &
    probe_pid=$!
    tries=0
    while ! netstat -ln 2>/dev/null | grep -q ":$port "; do
        kill -0 "$probe_pid" 2>/dev/null || probe_error probe_start_failed
        [ "$tries" -lt 5 ] || probe_error probe_listener_timeout
        sleep 1
        tries=$((tries + 1))
    done
    probe_stage=memory_admission
    subscription_probe_resources "$mode" "$streams" 1 || probe_error "$SUBSCRIPTION_PROBE_ERROR"
    proxy="http://127.0.0.1:$port"
    if [ "$mode" = services ]; then
        probe_stage=service_request
        subscription_services_probe "$section" "$item_id" "$4" "$proxy" "$work" || probe_error "${SUBSCRIPTION_PROBE_ERROR:-service_check_failed}"
        subscription_probe_diagnostic "$section" "$item_id" completed '' true
    elif [ "$mode" = ping ]; then
        result="$(curl -sS --proxy "$proxy" --noproxy '' --connect-timeout 7 -m 12 -o /dev/null -w '%{http_code} %{time_total}' https://www.gstatic.com/generate_204 2>"$work/curl.log")"
        rc=$?
        [ "$rc" -eq 0 ] || probe_error "probe_curl_$rc"
        printf '%s\n' "$result" | jq -R --arg id "$item_id" 'split(" ") | {success:(.[0] == "204"),id:$id,latencyMs:((.[1]|tonumber)*1000|round),httpCode:(.[0]|tonumber)}'
    else
        stream=1
        while [ "$stream" -le "$streams" ]; do
            (curl -sS --proxy "$proxy" --noproxy '' --connect-timeout 7 -m "$timeout" -o /dev/null \
                -w '%{http_code} %{size_download} %{time_total} %{time_starttransfer}' \
                "https://speed.cloudflare.com/__down?bytes=$bytes&probe=$$-$stream" 2>/dev/null; printf '\n') > "$work/stream.$stream" &
            curl_pids="$curl_pids $!"
            stream=$((stream + 1))
        done
        for child in $curl_pids; do wait "$child" 2>/dev/null || true; done
        curl_pids=""
        jq -Rsc --arg id "$item_id" --arg name "$name" --argjson requestedStreams "$requested_streams" --argjson streams "$streams" '
            split("\n") | map(select(length > 0) | split(" ") | map(tonumber?))
            | map(select(length == 4 and .[0] == 200 and .[1] >= 65536))
            | if length == 0 then {success:true,results:[{id:$id,name:$name,success:false,error:"download_failed",requestedStreams:$requestedStreams,streams:$streams}]}
              else (map(.[1])|add) as $bytes | (map(.[2]-.[3])|max) as $time
              | {success:true,results:[{id:$id,name:$name,tag:"isolated",success:($time>0),bytesPerSecond:(if $time>0 then $bytes/$time else 0 end),sizeDownload:$bytes,timeTotal:$time,httpCode:200,requestedStreams:$requestedStreams,streams:$streams}]} end
        ' "$work"/stream.*
    fi
    ) &
    isolated_worker_pid=$!
    # Shell functions with subshell bodies otherwise leave their children alive
    # when the calling CLI process receives cancellation.
    trap 'kill "$isolated_worker_pid" 2>/dev/null || true; wait "$isolated_worker_pid" 2>/dev/null || true; exit 130' INT TERM HUP
    isolated_worker_rc=0
    wait "$isolated_worker_pid" || isolated_worker_rc=$?
    trap - INT TERM HUP
    eval "$isolated_worker_traps"
    return "$isolated_worker_rc"
}

subscription_ping() {
    subscription_isolated_test "$1" "$2" ping
}

subscription_speedtest() {
    subscription_isolated_test "$1" "$2" speed
}
# subscription_isolated_probe_v1 end
