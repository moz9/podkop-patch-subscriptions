# Catalog-aware native sing-box DNS adapter. No Engine dependency.
sing_box_cf_add_dns_server() {
    local config="$1"
    local type="$2"
    local tag="$3"
    local server="$4"
    local domain_resolver="${5:-}"
    local detour="${6:-}"

    local server_address server_port catalog endpoint
    server_address=$(url_get_host "$server")
    server_port=$(url_get_port "$server")

    case "$type" in udp|tcp|doh|dot) ;; *) log "unsupported_engine_protocol: $type. Aborted." "fatal"; return 1;; esac
    catalog="${PODKOP_DNS_CATALOG_DIR:-/usr/share/podkop}/dns-main.json"
    # Bootstrap catalog is pinned to IPs, so encrypted bootstrap never needs itself.
    if [ "$tag" = "${SB_BOOTSTRAP_SERVER_TAG:-bootstrap}" ]; then catalog="${PODKOP_DNS_CATALOG_DIR:-/usr/share/podkop}/dns-bootstrap.json"; fi
    endpoint='{}'
    if [ -s "$catalog" ]; then
        endpoint=$(jq -ce --arg value "$server" --arg protocol "$type" '
            [.servers[]|select(.value==$value or ((.aliases//[])|index($value)))] as $rows |
            if ($rows|length)==0 then {} else
              [$rows[]|select(.protocols|index($protocol))][0] as $row |
              if $row==null then error("unsupported catalog protocol") else ($row.endpoints[$protocol]//{host:$row.value,port:53}) end
            end' "$catalog") || return 1
    fi
    local endpoint_host
    endpoint_host=$(printf '%s' "$endpoint" | jq -r --arg host "$server_address" '.host//$host')
    if [ "$tag" = "${SB_BOOTSTRAP_SERVER_TAG:-bootstrap}" ]; then
        if ! is_ipv4 "$endpoint_host"; then
            log "bootstrap_requires_ip: encrypted bootstrap cannot use system DNS. Aborted." "fatal"
            return 1
        fi
        domain_resolver=''
    elif [ -z "$domain_resolver" ]; then
        if ! is_ipv4 "$endpoint_host"; then domain_resolver="${SB_BOOTSTRAP_SERVER_TAG:-bootstrap}"; fi
    fi
    # Only transports checked against the installed native sing-box 1.12. No 1.14 fallback fields.
    echo "$config" | jq --arg type "$type" --arg tag "$tag" --arg host "$server_address" \
        --arg port "$server_port" --arg path "$(url_get_path "$server")" --arg resolver "$domain_resolver" --arg detour "$detour" --argjson endpoint "$endpoint" '
        .dns.servers += [({type:({udp:"udp",tcp:"tcp",doh:"https",dot:"tls",doq:"quic",h3:"h3"}[$type]),tag:$tag,
        server:($endpoint.host//$host),server_port:($endpoint.port//(if $port!="" then ($port|tonumber) else {udp:53,tcp:53,doh:443,dot:853,doq:853,h3:443}[$type] end))}
        + (if $type=="doh" or $type=="h3" then {path:($endpoint.path//(if $path=="" then "/dns-query" else $path end))} else {} end)
        + (if $endpoint.server_name then {tls:{enabled:true,server_name:$endpoint.server_name}} else {} end)
        + (if $resolver!="" then {domain_resolver:$resolver} else {} end)
        + (if $detour!="" then {detour:$detour} else {} end))]'
    return $?

}
