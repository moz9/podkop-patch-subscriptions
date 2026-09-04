# subscription_isolated_probe_v1 begin
# Diagnostics use a private loopback listener and never the working selector.
subscription_isolated_test() (
    section="$1"
    item_id="$2"
    mode="${3:-ping}"
    probe_pid=""
    curl_pids=""
    work=""
    locked=0
    cleanup_probe() {
        for child in $curl_pids; do kill "$child" 2>/dev/null || true; done
        if [ -n "$probe_pid" ]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi
        [ -z "$work" ] || rm -rf "$work"
        [ "$locked" -eq 0 ] || subscription_action_lock_release
    }
    trap cleanup_probe EXIT
    trap 'exit 130' INT TERM HUP
    probe_error() { jq -cn --arg error "$1" '{success:false,error:$error}'; exit 1; }
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || probe_error invalid_section
    validate_subscription_link_id "$item_id" || probe_error invalid_link_id
    case "$mode" in ping|speed) ;; *) probe_error invalid_probe_mode ;; esac
    subscription_action_lock_acquire "isolated_$mode" || probe_error service_busy
    locked=1
    umask 077
    work="$(mktemp -d /tmp/podkop-subscription-probe.XXXXXX)" || probe_error temporary_directory_failed
    items="$(get_subscription_items_cache_path "$section")"
    jq -e --arg id "$item_id" 'any(.[]; .id == $id and .supported == true)' "$items" >/dev/null 2>&1 || probe_error subscription_link_not_available
    link=""
    while IFS= read -r candidate || [ -n "$candidate" ]; do
        if [ "$(get_subscription_link_id "$candidate")" = "$item_id" ]; then link="$candidate"; break; fi
    done < "$(get_subscription_all_cache_path "$section")"
    [ -n "$link" ] || probe_error subscription_link_not_available
    name="$(jq -r --arg id "$item_id" '.[] | select(.id == $id) | .name' "$items")"
    # Retain configured real DNS servers, but not FakeIP rules or production detours.
    config="$(jq -c '{dns:{servers:[.dns.servers[] | select(.type != "fakeip") | del(.detour)], final:.dns.final, strategy:"ipv4_only"},
        inbounds:[],outbounds:[],route:{default_mark:2097152,default_domain_resolver:.route.default_domain_resolver},log:{level:"warn"}}' /etc/sing-box/config.json)" || probe_error dns_config_invalid
    config_get udp_over_tcp "$section" enable_udp_over_tcp
    config="$(sing_box_cf_add_proxy_outbound "$config" subscription-probe "$link" "$udp_over_tcp" 2>"$work/parser.log")" || probe_error invalid_config
    tag="$(get_outbound_tag_by_section subscription-probe)"
    port=$((43000 + $$ % 1000))
    tries=0
    while netstat -ln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1)); tries=$((tries + 1))
        [ "$tries" -lt 20 ] || probe_error probe_port_busy
    done
    printf '%s\n' "$config" | jq --arg tag "$tag" --argjson port "$port" '
        .inbounds = [{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:$port}]
        | .route.final = $tag' > "$work/config.json" || probe_error invalid_config
    sing-box check -c "$work/config.json" >"$work/check.log" 2>&1 || probe_error invalid_config
    sing-box run -c "$work/config.json" >"$work/runtime.log" 2>&1 &
    probe_pid=$!
    sleep 1
    kill -0 "$probe_pid" 2>/dev/null || probe_error probe_start_failed
    proxy="http://127.0.0.1:$port"
    if [ "$mode" = ping ]; then
        result="$(curl -sS --proxy "$proxy" --noproxy '' --connect-timeout 7 -m 12 -o /dev/null -w '%{http_code} %{time_total}' https://www.gstatic.com/generate_204 2>"$work/curl.log")"
        rc=$?
        [ "$rc" -eq 0 ] || probe_error "probe_curl_$rc"
        printf '%s\n' "$result" | jq -R --arg id "$item_id" 'split(" ") | {success:(.[0] == "204"),id:$id,latencyMs:((.[1]|tonumber)*1000|round),httpCode:(.[0]|tonumber)}'
    else
        bytes="$(get_subscription_benchmark_bytes)"
        streams="$(get_subscription_benchmark_streams)"
        timeout="$(get_subscription_benchmark_timeout)"
        case "$bytes:$streams:$timeout" in *[!0-9:]*|'') probe_error invalid_benchmark_options ;; esac
        [ "$streams" -ge 1 ] && [ "$streams" -le 8 ] && [ "$timeout" -ge 1 ] && [ "$timeout" -le 60 ] && [ "$bytes" -ge 65536 ] || probe_error invalid_benchmark_options
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
        jq -Rsc --arg id "$item_id" --arg name "$name" '
            split("\n") | map(select(length > 0) | split(" ") | map(tonumber?))
            | map(select(length == 4 and .[0] == 200 and .[1] >= 65536))
            | if length == 0 then {success:true,results:[{id:$id,name:$name,success:false,error:"download_failed"}]}
              else (map(.[1])|add) as $bytes | (map(.[2]-.[3])|max) as $time
              | {success:true,results:[{id:$id,name:$name,tag:"isolated",success:($time>0),bytesPerSecond:(if $time>0 then $bytes/$time else 0 end),sizeDownload:$bytes,timeTotal:$time,httpCode:200}]} end
        ' "$work"/stream.*
    fi
)

subscription_ping() {
    subscription_isolated_test "$1" "$2" ping
}

subscription_speedtest() {
    subscription_isolated_test "$1" "$2" speed
}
# subscription_isolated_probe_v1 end
