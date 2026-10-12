# subscription_sources_v1 begin
# A source is identified by its URL hash, never by its position in the UI.
# subscription_source_actions_v1
# subscription_choices_and_busy_v1
# subscription_selection_v1
# subscription_tag_filters_v1
# subscription_tag_glob_portable_v1
# subscription_jq16_policy_v1
# subscription_service_filter_v1
# subscription_game_filter_v1
# subscription_resource_admission_v1
# Conservative software budgets, not measurements of any particular router.
# Reject complete candidates; never truncate a subscription to make it fit.
subscription_resource_limits() {
    SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES="${PODKOP_SUBSCRIPTION_MAX_SOURCE_BYTES:-1048576}"
    SUBSCRIPTION_RESOURCE_MAX_NODES="${PODKOP_SUBSCRIPTION_MAX_NODES:-2048}"
    # Administrator overrides are bounded and still subject to live memory
    # admission. Reject malformed/overflowing values instead of truncating them.
    case "$SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES:$SUBSCRIPTION_RESOURCE_MAX_NODES" in *[!0-9:]*|:*|*:) SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;; esac
    [ "${#SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES}" -le 8 ] && [ "${#SUBSCRIPTION_RESOURCE_MAX_NODES}" -le 4 ] || {
        SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;
    }
    while [ "${SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES#0}" != "$SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES" ]; do SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES="${SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES#0}"; done
    while [ "${SUBSCRIPTION_RESOURCE_MAX_NODES#0}" != "$SUBSCRIPTION_RESOURCE_MAX_NODES" ]; do SUBSCRIPTION_RESOURCE_MAX_NODES="${SUBSCRIPTION_RESOURCE_MAX_NODES#0}"; done
    [ "${SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES:-0}" -ge 65536 ] && [ "${SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES:-0}" -le 4194304 ] &&
        [ "${SUBSCRIPTION_RESOURCE_MAX_NODES:-0}" -ge 1 ] && [ "${SUBSCRIPTION_RESOURCE_MAX_NODES:-0}" -le 8192 ] || {
        SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;
    }
    SUBSCRIPTION_RESOURCE_MAX_CACHE_BYTES=$((SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES * 8))
}

subscription_download_pid_start() {
    local stat parent="${2:-}"
    [ -r "/proc/$1/stat" ] || return 1
    IFS= read -r stat < "/proc/$1/stat" || return 1
    stat="${stat##*) }"
    set -- $stat
    [ "$#" -ge 20 ] || return 1
    [ -z "$parent" ] || [ "$2" = "$parent" ] || return 1
    shift 19
    printf '%s\n' "$1"
}

subscription_download_kill_child() {
    local pid="$1" identity="$2" parent="${3:-}"
    [ -n "$pid" ] && [ -n "$identity" ] || return 0
    # Check Linux starttime again before each signal; a completed child PID may
    # have been reaped/reused while the parent was handling another event.
    [ "$(subscription_download_pid_start "$pid" "$parent" 2>/dev/null)" = "$identity" ] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    [ "$(subscription_download_pid_start "$pid" "$parent" 2>/dev/null)" = "$identity" ] || return 0
    kill -KILL "$pid" 2>/dev/null || true
}

subscription_download_guarded() {
    local body="$1" headers="$2" child='' identity='' parent_pid self_stat status=0 saved_traps trapfile started now deadline launching=0 stopped=0
    shift 2
    deadline="${PODKOP_SUBSCRIPTION_DOWNLOAD_TIMEOUT_SECONDS:-45}"
    case "$deadline" in ''|*[!0-9]*|0*) SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;; esac
    [ "${#deadline}" -le 2 ] && [ "$deadline" -le 60 ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1; }
    started="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)" || started=''
    case "$started" in ''|*[!0-9]*) SUBSCRIPTION_RESOURCE_ERROR=subscription_download_incomplete; return 1;; esac
    # Read our actual shell PID, including when running in a command substitution
    # where POSIX $$ still denotes the outer shell.
    IFS= read -r self_stat < /proc/self/stat || return 1
    parent_pid="${self_stat%% *}"
    # `saved=$(trap)` loses traps in dash; capture in this shell first.
    trapfile="$(mktemp)" || return 1
    trap > "$trapfile"
    saved_traps="$(cat "$trapfile")"
    rm -f "$trapfile"
    subscription_download_stop() {
        # Defer a signal in the fork -> PID/starttime recording window.
        if [ "$launching" = 1 ]; then stopped=1; return; fi
        trap '' INT TERM HUP
        subscription_download_kill_child "$child" "$identity" "$parent_pid"
        [ -z "$child" ] || wait "$child" 2>/dev/null || true
        rm -f "$body" "$headers"
        trap - INT TERM HUP
        eval "$saved_traps"
        # Restored EXIT cleanup releases the worker mutation lock.
        exit 143
    }
    trap 'subscription_download_stop' INT TERM HUP
    launching=1
    (
        ulimit -f "$(((SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES + 511) / 512))" || exit 1
        exec "$@"
    ) &
    child=$!
    identity="$(subscription_download_pid_start "$child" "$parent_pid" 2>/dev/null)" || identity=''
    launching=0
    [ "$stopped" = 0 ] || subscription_download_stop
    while kill -0 "$child" 2>/dev/null; do
        now="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)" || now=''
        case "$now" in ''|*[!0-9]*) now=$((started + deadline));; esac
        if [ "$((now - started))" -ge "$deadline" ]; then
            subscription_download_kill_child "$child" "$identity" "$parent_pid"
            wait "$child" 2>/dev/null || true
            status=124
            break
        fi
        sleep 1
    done
    if [ "$status" -eq 0 ]; then wait "$child" || status=$?; fi
    child=''
    trap - INT TERM HUP
    eval "$saved_traps"
    return "$status"
}

subscription_resource_memory() {
    local bytes="$1" nodes="$2" available required
    subscription_resource_limits || return 1
    case "$bytes:$nodes" in *[!0-9:]*|:*|*:) SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;; esac
    case "$bytes:$nodes" in 0[0-9]*:*|*:0[0-9]*) SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;; esac
    [ "${#bytes}" -le 8 ] && [ "${#nodes}" -le 5 ] && [ "$bytes" -le 67108864 ] && [ "$nodes" -le 16384 ] || {
        SUBSCRIPTION_RESOURCE_ERROR=subscription_resource_limits_invalid; return 1;
    }
    available="$(awk '/^MemAvailable:/ {print $2; exit}' "${PODKOP_SUBSCRIPTION_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null)" || available=''
    case "$available" in ''|*[!0-9]*) SUBSCRIPTION_RESOURCE_ERROR=subscription_memory_unavailable; return 1;; esac
    [ "${#available}" -le 10 ] && [ "$available" -le 2147483647 ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_memory_unavailable; return 1; }
    # Keep 16 MiB for active services, allow twelve copies of input/cache bytes
    # and 16 KiB per old/candidate node for parsing, JSON and identity indexes.
    required=$((16384 + (bytes + 1023) / 1024 * 12 + nodes * 16))
    [ "$available" -ge "$required" ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_insufficient_memory; return 1; }
}

subscription_resource_bytes() {
    local path size total=0
    subscription_resource_limits || return 1
    for path in "$@"; do
        [ -f "$path" ] || continue
        size="$(wc -c < "$path")" || return 1
        # Bound arithmetic as well as the data passed to jq and the parser.
        [ "$size" -le "$SUBSCRIPTION_RESOURCE_MAX_CACHE_BYTES" ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_cache_too_large; return 1; }
        total=$((total + size))
        [ "$total" -le "$SUBSCRIPTION_RESOURCE_MAX_CACHE_BYTES" ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_cache_too_large; return 1; }
    done
    SUBSCRIPTION_RESOURCE_BYTES="$total"
}

subscription_resource_source() {
    local size
    subscription_resource_limits || return 1
    size="$(wc -c < "$1")" || return 1
    [ "$size" -le "$SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES" ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_too_large; return 1; }
}

subscription_resource_links() {
    local nodes
    subscription_resource_source "$1" || return 1
    # Count before expensive per-node parser processes and growing JSON strings.
    nodes="$(LC_ALL=C awk 'length($0)>16384 {large=1} NF {n++} END {if(large) print "large"; else print n+0}' "$1")" || return 1
    [ "$nodes" != large ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_link_too_large; return 1; }
    [ "$nodes" -le "$SUBSCRIPTION_RESOURCE_MAX_NODES" ] || { SUBSCRIPTION_RESOURCE_ERROR=subscription_too_many_nodes; return 1; }
    SUBSCRIPTION_RESOURCE_NODES="$nodes"
}

subscription_resource_cache() {
    local section="$1" items
    items="$(get_subscription_items_cache_path "$section")"
    subscription_resource_bytes "$items" "$(get_subscription_cache_path "$section")" \
        "$(get_subscription_all_cache_path "$section")" "$(get_subscription_skipped_cache_path "$section")" || return 1
    SUBSCRIPTION_RESOURCE_OLD_BYTES="$SUBSCRIPTION_RESOURCE_BYTES"
    # Admit bounded JSON parsing before asking jq to count an existing cache.
    subscription_resource_memory "$((SUBSCRIPTION_RESOURCE_OLD_BYTES + SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES))" 0 || return 1
    SUBSCRIPTION_RESOURCE_OLD_NODES=0
    if [ -s "$items" ]; then
        SUBSCRIPTION_RESOURCE_OLD_NODES="$(jq -er --argjson max "$SUBSCRIPTION_RESOURCE_MAX_NODES" 'if type=="array" and length<=$max then length else error("invalid_cache") end' "$items" 2>/dev/null)" || {
            SUBSCRIPTION_RESOURCE_ERROR=subscription_cache_invalid; return 1;
        }
    fi
    subscription_resource_memory "$((SUBSCRIPTION_RESOURCE_OLD_BYTES + SUBSCRIPTION_RESOURCE_MAX_SOURCE_BYTES))" "$SUBSCRIPTION_RESOURCE_OLD_NODES"
}

subscription_tag_values_append() {
    SUBSCRIPTION_TAG_VALUES="$(printf '%s' "$SUBSCRIPTION_TAG_VALUES" | jq -c --arg value "$1" '. + [$value]')"
}

subscription_tags_json() {
    SUBSCRIPTION_TAG_VALUES='[]'
    config_list_foreach "$1" "$2" subscription_tag_values_append
    printf '%s\n' "$SUBSCRIPTION_TAG_VALUES"
}

subscription_tags_prepare() {
    local section="$1" changes="$2" dir="$SUBSCRIPTION_APPLY_V2_TMP" option value current proposed
    SUBSCRIPTION_TAGS_CHANGED=0
    for option in include exclude; do
        current="$(subscription_tags_json "$section" "subscription_${option}_tags")" || return 1
        proposed="$(printf '%s' "$changes" | jq -c --arg option "${option}Tags" --argjson current "$current" '.[$option] // $current')" || return 1
        printf '%s\n' "$proposed" > "$dir/tags.$section.$option" || return 1
        [ "$current" = "$proposed" ] || SUBSCRIPTION_TAGS_CHANGED=$((SUBSCRIPTION_TAGS_CHANGED + 1))
    done
}

subscription_tags_stage() {
    local section="$1" option value proposed current
    for option in include exclude; do
        proposed="$(cat "$SUBSCRIPTION_APPLY_V2_TMP/tags.$section.$option")" || return 1
        current="$(subscription_tags_json "$section" "subscription_${option}_tags")" || return 1
        [ "$proposed" != "$current" ] || continue
        subscription_cas_uci -q delete "podkop.$section.subscription_${option}_tags" >/dev/null 2>&1 || true
        printf '%s' "$proposed" | jq -r '.[]' > "$SUBSCRIPTION_APPLY_V2_TMP/tags.$section.$option.list" || return 1
        while IFS= read -r value; do
            subscription_cas_uci -q add_list "podkop.$section.subscription_${option}_tags=$value" || return 1
        done < "$SUBSCRIPTION_APPLY_V2_TMP/tags.$section.$option.list"
    done
}

subscription_tags_verify() {
    local section="$1" option
    for option in include exclude; do
        [ "$(subscription_tags_json "$section" "subscription_${option}_tags")" = "$(cat "$SUBSCRIPTION_APPLY_V2_TMP/tags.$section.$option")" ] || return 1
    done
}

subscription_selection_mode() {
    local mode=''
    config_get mode "$1" subscription_selection_mode
    case "$mode" in selected|all) printf '%s\n' "$mode" ;; *) printf 'auto\n' ;; esac
}

subscription_selected_ids_json() {
    local ids='' id
    config_get ids "$1" subscription_selected_link_ids
    for id in $ids; do
        case "$id" in *[!a-f0-9]*|'') continue ;; esac
        [ "${#id}" -ne 32 ] || printf '%s\n' "$id"
    done | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

# Freeze the current effective choices before applying a mode transition and row edits.
subscription_selection_prepare() {
    local section="$1" changes="$2" items="$3" excluded="$4" dir="$SUBSCRIPTION_APPLY_V2_TMP"
    local current mode selected id enabled selection_id was_selected count=0 include_tags='[]' exclude_tags='[]'
    current="$(subscription_selection_mode "$section")"
    mode="$(printf '%s' "$changes" | jq -r --arg current "$current" '.selectionMode // $current')"
    selected="$(subscription_selected_ids_json "$section")" || return 1
    if [ "$mode" != "$current" ]; then
        count=1
        if [ "$mode" = selected ] && { [ "$current" != auto ] || [ "$selected" = '[]' ]; }; then
            subscription_items_with_sources "$section" "$items" > "$dir/selection.$section.items" || return 1
            if [ "$current" = auto ]; then
                include_tags="$(subscription_tags_json "$section" subscription_include_tags)" || return 1
                exclude_tags="$(subscription_tags_json "$section" subscription_exclude_tags)" || return 1
            fi
            selected="$(subscription_source_policy "$(subscription_disabled_sources_json "$section")" "$excluded" \
                "$dir/selection.$section.items" "$current" '[]' "$include_tags" "$exclude_tags" \
                | jq -c '[.[] | select(.runtimeEnabled) | .selectionId // .id] | unique')" || return 1
        fi
    fi
    if [ "$mode" = selected ]; then
        printf '%s' "$changes" | jq -r '.changes[] | [.id,.enabled] | @tsv' > "$dir/selection.$section.changes" || return 1
        while IFS="$(printf '\t')" read -r id enabled; do
            [ -n "$id" ] || continue
            selection_id="$(jq -r --arg id "$id" '.[] | select(.id==$id and .supported) | .selectionId // .id' "$items")"
            validate_subscription_link_id "$id" && validate_subscription_link_id "$selection_id" || return 1
            was_selected="$(printf '%s' "$selected" | jq --arg id "$selection_id" 'index($id)!=null')"
            [ "$was_selected" = "$enabled" ] || count=$((count + 1))
            selected="$(printf '%s' "$selected" | jq -c --arg id "$selection_id" --argjson enabled "$enabled" \
                'map(select(.!=$id)) + (if $enabled then [$id] else [] end) | unique')" || return 1
        done < "$dir/selection.$section.changes"
    fi
    printf '%s\n' "$current" > "$dir/selection.$section.current-mode"
    printf '%s\n' "$mode" > "$dir/selection.$section.mode"
    printf '%s\n' "$selected" > "$dir/selection.$section.ids"
    SUBSCRIPTION_SELECTION_MODE="$mode"
    SUBSCRIPTION_SELECTION_CHANGED="$count"
}

subscription_selection_stage() {
    local section="$1" dir="$SUBSCRIPTION_APPLY_V2_TMP" mode current id
    mode="$(cat "$dir/selection.$section.mode")"
    current="$(cat "$dir/selection.$section.current-mode")"
    if [ "$mode" != "$current" ]; then
        subscription_cas_uci -q set "podkop.$section.subscription_selection_mode=$mode" || return 1
    fi
    [ "$mode" = selected ] || return 0
    subscription_cas_uci -q delete "podkop.$section.subscription_selected_link_ids" >/dev/null 2>&1 || true
    jq -r '.[]' "$dir/selection.$section.ids" > "$dir/selection.$section.list" || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        subscription_cas_uci -q add_list "podkop.$section.subscription_selected_link_ids=$id" || return 1
    done < "$dir/selection.$section.list"
}

subscription_selection_verify() {
    local section="$1" dir="$SUBSCRIPTION_APPLY_V2_TMP" mode
    mode="$(cat "$dir/selection.$section.mode")"
    [ "$mode" = "$(subscription_selection_mode "$section")" ] || return 1
    [ "$mode" = selected ] || return 0
    [ "$(cat "$dir/selection.$section.ids")" = "$(subscription_selected_ids_json "$section")" ]
}

subscription_connection_key() {
    # Labels and query ordering are not connection changes. Never persist credentials separately.
    local base="${1%%#*}" query
    case "$base" in
        *\?*) query="${base#*\?}"; base="${base%%\?*}" ;;
        *) query='' ;;
    esac
    { printf '%s\n' "$base"; printf '%s' "$query" | tr '&' '\n' | LC_ALL=C sort; } | md5sum | awk '{print $1}'
}

subscription_index_choices() {
    local items="$1" links="$2" map link
    map="$(mktemp)" || return 1
    if [ -s "$links" ]; then
        while IFS= read -r link || [ -n "$link" ]; do
            [ -n "$link" ] || continue
            printf '%s %s\n' "$(get_subscription_link_id "$link")" "$(subscription_connection_key "$link")"
        done < "$links" > "$map"
    fi
    jq --rawfile keys "$map" '
        ($keys | split("\n") | map(select(length>0) | split(" ") | {key:.[0],value:.[1]}) | from_entries) as $keys
        | map(.connectionKey = ($keys[.id] // .connectionKey // ""))
    ' "$items"
    local rc=$?; rm -f "$map"; return "$rc"
}

subscription_reconcile_choices() {
    jq --slurpfile old "$1" '
        . as $new
        | def same_source($a;$b): any(($a.sourceIds // [])[]; . as $s | ($b.sourceIds // [] | index($s)) != null);
          def identity_key($kind):
            if $kind=="id" then .id
            elif $kind=="key" then .connectionKey
            else [.name,.protocol,(.transport // "")] end | tojson;
          # Store row numbers, not five copies of credential-bearing node objects.
          # Restrict ambiguity checks to a matching bucket rather than scanning
          # both complete subscriptions for every node (quadratic refresh cost).
          def row_index($rows;$kind):
            reduce range(0; $rows|length) as $i ({};
                ($rows[$i] | identity_key($kind)) as $key
                | .[$key] += [$i]);
          def candidates($rows;$index;$kind;$item):
            # Two matches already prove ambiguity; do not materialize a giant
            # duplicate bucket just to test whether its cardinality is one.
            [limit(2; $index[($item|identity_key($kind))][]? as $i
             | $rows[$i] | select(same_source(.;$item)))];
          row_index($old[0];"id") as $old_id
          | row_index($old[0];"key") as $old_key
          | row_index($old[0];"name") as $old_name
          | row_index($new;"key") as $new_key
          | row_index($new;"name") as $new_name
          | map(. as $item
            | ($old_id[($item|identity_key("id"))] // []) as $exact
            | (if ($exact|length)==1 then $old[0][$exact[0]]
               else (if ($item.connectionKey // "") != "" then candidates($old[0];$old_key;"key";$item) else [] end) as $key
                 | if ($key|length)==1 and (candidates($new;$new_key;"key";$item)|length)==1 then $key[0]
                   else (if ($item.name // "") != "" then candidates($old[0];$old_name;"name";$item) else [] end) as $name
                     | if ($name|length)==1 and (candidates($new;$new_name;"name";$item)|length)==1 then $name[0]
                       else null end
                   end
               end) as $previous
            | .selectionId=($previous.selectionId // $previous.id // .id)
            | .selectionNew=($previous==null and ($old[0]|length)>0))
    ' "$2"
}

get_subscription_operation_status() {
    # single_runtime_status_v1: scoped settings, shared process lifecycle.
    if command -v podkop_section_single_mode >/dev/null && podkop_section_single_mode; then
        local single_busy=false single_pending=false single_names single_status single_pending_sections
        subscription_runtime_busy && single_busy=true
        [ ! -f "$(subscription_reload_pending_file)" ] || single_pending=true
        single_names="$(podkop_section_names)" || single_names='[]'
        single_status="$(podkop_section_manager status 2>/dev/null)" || single_status='{}'
        if command -v subscription_pending_sections_json >/dev/null; then
            single_pending_sections="$(subscription_pending_sections_json)" || single_pending_sections='[]'
        elif [ "$single_pending" = true ]; then single_pending_sections="$single_names"
        else single_pending_sections='[]'; fi
        printf '%s' "$single_status" | jq -c --argjson busy "$single_busy" --argjson pending "$single_pending" \
            --argjson names "$single_names" --argjson pendingSections "$single_pending_sections" \
            '{busy:$busy,pending:$pending,pendingSections:$pendingSections,runtimeMode:"single",isolatedSection:($names[0]//""),isolatedSections:$names,sections:(.sections//[]),isolatedReady:(.ready==true and ($names|length)>0),retryAfter:3,reason:(if $busy then "service_busy" else "" end)}'
        return
    fi
    local busy=false pending=false isolated="" ready=false isolated_sections='[]' section_status='[]' status pending_sections='[]'
    subscription_runtime_busy && busy=true
    [ ! -f "$(subscription_reload_pending_file)" ] || pending=true
    pending_sections="$(subscription_pending_sections_json)" || pending_sections='[]'
    if command -v podkop_section_enabled >/dev/null && podkop_section_enabled; then
        isolated="$(podkop_section_name)"
        isolated_sections="$(podkop_section_names)" || isolated_sections='[]'
        status="$(podkop_section_manager status 2>/dev/null)" || status='{}'
        section_status="$(printf '%s' "$status" | jq -ce '.sections // []')" || section_status='[]'
        printf '%s' "$status" | jq -e --argjson registered "$isolated_sections" '.ready==true and ($registered|length>0) and ((.sections|map(.section)|sort)==($registered|sort)) and all(.sections[];.ready==true)' >/dev/null && ready=true
    fi
    jq -cn --argjson busy "$busy" --argjson pending "$pending" --arg isolated "$isolated" --argjson ready "$ready" \
        --argjson isolatedSections "$isolated_sections" --argjson sections "$section_status" --argjson pendingSections "$pending_sections" \
        '{busy:$busy,pending:$pending,pendingSections:$pendingSections,isolatedSection:$isolated,isolatedSections:$isolatedSections,sections:$sections,isolatedReady:$ready,retryAfter:3,reason:(if $busy then "service_busy" else "" end)}'
}

subscription_cached_source_append() {
    local section="$1" source_id="$2" source_index="$3" active="$4" all="$5" skipped="$6" items="$7"
    local cached source_items link id count expected all_cache skipped_cache
    cached="$(get_subscription_items_cache_path "$section")"
    [ -s "$cached" ] || return 0
    source_items="$(jq -c --arg id "$source_id" --argjson index "$source_index" '
        map(select(if (.sourceIds // [] | length) > 0 then (.sourceIds | index($id)) != null else (.sourceIndex // 1) == $index end)
            | .sourceIds=[$id] | .sourceIndex=$index | .sourceName=("Subscription " + ($index|tostring)))
    ' "$cached")" || return 1
    printf '%s\n' "$source_items" | jq -c '.[]' >> "$items" || return 1
    all_cache="$(get_subscription_all_cache_path "$section")"
    count=0
    if [ -s "$all_cache" ]; then
        while IFS= read -r link || [ -n "$link" ]; do
            [ -n "$link" ] || continue
            id="$(get_subscription_link_id "$link")"
            if printf '%s\n' "$source_items" | jq -e --arg id "$id" 'any(.[]; .id==$id and .supported)' >/dev/null; then
                printf '%s\n' "$link" >> "$all"
                count=$((count + 1))
                if printf '%s\n' "$source_items" | jq -e --arg id "$id" 'any(.[]; .id==$id and .enabled)' >/dev/null; then
                    printf '%s\n' "$link" >> "$active"
                fi
            fi
        done < "$all_cache"
    fi
    expected="$(printf '%s\n' "$source_items" | jq '[.[] | select(.supported)] | length')"
    [ "$count" -eq "$expected" ] || return 1
    skipped_cache="$(get_subscription_skipped_cache_path "$section")"
    if [ -s "$skipped_cache" ]; then
        jq -c --argjson items "$source_items" '.[] | . as $skip | select(any($items[]; .id==$skip.id))' "$skipped_cache" >> "$skipped" || return 1
    fi
    return 0
}

subscription_source_policy() {
    local services="${8:-}"
    [ -n "$services" ] || services='{"required":[],"results":[]}'
    printf '%s\n' "$services" | jq -c --argjson country_map "$(if command -v subscription_services_country_map >/dev/null 2>&1; then subscription_services_country_map; else printf '{}\n'; fi)" --argjson now "$(date +%s)" --argjson disabled "$1" --argjson excluded "$2" --arg mode "${4:-all}" --argjson selected "${5:-[]}" \
        --argjson include_patterns "${6:-[]}" --argjson exclude "${7:-[]}" --slurpfile policy_items "$3" '
        . as $services
        | ($services.results | map({key:.id,value:.services}) | from_entries) as $service_status
        | $policy_items[0]
        |
        def glob_tokens:
            explode as $chars
            | reduce range(0; $chars|length) as $i
                ({tokens:[],skip:-1};
                 if $i <= .skip then .
                 elif $chars[$i] == 92 and $i+1 < ($chars|length) then
                    .tokens += [{kind:"literal",value:$chars[$i+1]}] | .skip=$i+1
                 elif $chars[$i] == 91 then
                    ([range($i+1; $chars|length) | select($chars[.] == 93)] | .[0] // -1) as $close
                    | if $close > $i+1 then
                        .tokens += [{kind:"class",value:$chars[$i+1:$close]}] | .skip=$close
                      else .tokens += [{kind:"literal",value:91}] end
                 elif $chars[$i] == 42 then .tokens += [{kind:"star"}]
                 elif $chars[$i] == 63 then .tokens += [{kind:"any"}]
                 else .tokens += [{kind:"literal",value:$chars[$i]}] end)
            | .tokens;
        def class_has($class; $code):
            (($class[0] == 33) or ($class[0] == 94)) as $negated
            | (if $negated then $class[1:] else $class end) as $body
            | any(range(0; $body|length); . as $i
                | if $body[$i] == 45 and $i > 0 and $i+1 < ($body|length) then false
                  elif $i+2 < ($body|length) and $body[$i+1] == 45 then
                    $code >= $body[$i] and $code <= $body[$i+2]
                  else $code == $body[$i] end) as $hit
            | if $negated then ($hit|not) else $hit end;
        def glob_matches($glob; $name):
            ($glob | glob_tokens) as $tokens
            | ($name | explode) as $chars
            | reduce $tokens[] as $token ([0];
                if length == 0 then []
                elif $token.kind == "star" then [range(min; ($chars|length)+1)]
                else [.[] | select(. < ($chars|length))
                    | . as $pos
                    | select(if $token.kind == "any" then true
                             elif $token.kind == "class" then class_has($token.value; $chars[$pos])
                             else $token.value == $chars[$pos] end)
                    | .+1] | unique end)
            | index($chars|length) != null;
        def country_code($text):
            ($text | explode) as $codes
            | if ($codes | length) == 2 and all($codes[]; . >= 65 and . <= 90) then $text else null end;
        def flag_for($code): [$code | explode[] | . + 127397] | implode;
        def whitespace: . == 32 or (. >= 9 and . <= 13) or . == 160 or . == 5760
            or (. >= 8192 and . <= 8202) or . == 8232 or . == 8233 or . == 8239
            or . == 8287 or . == 12288 or . == 65279;
        def trim_name:
            explode as $chars
            | [$chars | to_entries[] | select(.value | whitespace | not) | .key] as $visible
            | if ($visible|length) == 0 then "" else $chars[$visible[0]:($visible[-1]+1)] | implode end;
        def leading_code($code; $name):
            ($name | trim_name) as $name
            |
            ($name | startswith($code)) and
            (($name | length) == 2 or any($name[2:3] | explode[]; whitespace)
                or ([".","_",":","/","-"] | index($name[2:3]) != null));
        def prefix_matches($code; $name):
            ($name | contains(flag_for($code))) or leading_code($code; $name);
        def legacy_flag_code($pattern):
            ($pattern | explode) as $codes
            | if ($codes | length) == 4 and $codes[0] == 42 and $codes[3] == 42
                 and all($codes[1:3][]; . >= 127462 and . <= 127487)
              then [$codes[1:3][] | . - 127397] | implode
              else null end;
        def pattern_matches($pattern; $name):
            (legacy_flag_code($pattern)) as $legacy_code
            | if $pattern == "@game:only" then ($name | contains("Игровой") | not)
              elif $pattern == "@game:exclude" then ($name | contains("Игровой"))
              elif ($pattern | startswith("@prefix:")) and (country_code($pattern[8:]) != null)
              then prefix_matches($pattern[8:]; $name)
              elif $legacy_code != null then prefix_matches($legacy_code; $name)
              else glob_matches($pattern; $name) end;
        def matches($patterns; $name): any($patterns[]; pattern_matches(.; $name));
        def google_declared($name):
            ($name|explode) as $chars
            | [range(0; (($chars|length)-1)) | . as $i
                | select(all($chars[$i:$i+2][]; .>=127462 and .<=127487))
                | [$chars[$i:$i+2][]|.-127397]|implode] as $flags
            | (if ($chars|length)>=2 and all($chars[0:2][]; .>=65 and .<=90)
                and (($chars|length)==2 or ([" ","\t","\n","\r","\f",".","_",":","/","-"]|index($name[2:3])!=null))
                then [$name[0:2]] else [] end) as $leading
            | ($flags+$leading|unique) as $candidates
            | if ($candidates|length)==1 and ($country_map[$candidates[0]]!=null)
              then $candidates[0] else null end;
        map(. as $item
            | .enabled = (.supported == true and (if $mode=="selected" then
                ($selected | index($item.selectionId // $item.id)) != null
                elif $mode=="all" then ($excluded | index($item.id)) == null and ($excluded | index($item.selectionId // $item.id)) == null
                else true end))
            | .sourceEnabled = (if ((.sourceIds // []) | length) > 0 then
                any(.sourceIds[]; . as $id | ($disabled | index($id)) == null)
                else ($disabled | length) == 0 end)
            | .tagExcluded = ((($include_patterns|length)>0 and (matches($include_patterns; $item.name // $item.tag // "")|not)) or matches($exclude; $item.name // $item.tag // ""))
            | .serviceExcluded = (all($services.required[]; . as $service
                | $service_status[$item.id][$service] as $proof
                | $proof.state=="pass" and (if $service=="exit_country" then
                    $proof.proofVersion==1 and $proof.manual==false
                    and $proof.declaredName==($item.name // $item.tag // "")
                    and ($proof.declaredCountry|type=="string" and length==2)
                    and $proof.network=="pass"
                    and $proof.declaredCountry==google_declared($item.name // $item.tag // "")
                    and ($proof.checkedAt|type=="number") and $proof.checkedAt>0 and $proof.checkedAt<=$now
                    and ($proof.expiresAt|type=="number") and $proof.expiresAt>$now and $proof.expiresAt<=($proof.checkedAt+86400)
                    and $proof.exitCountry==$proof.declaredCountry
                    and ($proof.observations|type=="array" and length==2
                        and (map(.provider)|sort)==["ipinfo","ipwhois"]
                        and all(.[]; .valid==true and .country==$proof.exitCountry))
                  elif $service=="google_country" then
                    $proof.proofVersion==1 and $proof.manual==false
                    and $proof.network=="pass" and $proof.httpCode==200
                    and $proof.declaredName==($item.name // $item.tag // "")
                    and ($proof.declaredCountry|type=="string" and length==2)
                    and $proof.declaredCountry==google_declared($item.name // $item.tag // "")
                    and ($proof.googleCountry|type=="string" and length==2)
                    and ($proof.region|type=="string" and length==3)
                    and $country_map[$proof.region]==$proof.googleCountry
                    and $country_map[$proof.googleCountry]==$proof.region
                    and $proof.googleCountry==$proof.declaredCountry
                    and ($proof.checkedAt|type=="number") and $proof.checkedAt>0 and $proof.checkedAt<=$now
                    and ($proof.expiresAt|type=="number") and $proof.expiresAt>$now and $proof.expiresAt<=($proof.checkedAt+86400)
                  else true end)) | not)
            | .runtimeEnabled = (.enabled and .sourceEnabled and (.tagExcluded|not) and (.serviceExcluded|not))
            | if .supported then .reason = (if .enabled and .tagExcluded then "tag_filtered" elif .enabled then "" elif $mode=="selected" then "user_unselected" else "user_excluded" end) else . end)
    '
}

subscription_disabled_sources_json() {
    local ids id
    config_get ids "$1" subscription_disabled_source_ids
    for id in $ids; do
        case "$id" in *[!a-f0-9]*|'') continue ;; esac
        [ "${#id}" -ne 32 ] || printf '%s\n' "$id"
    done | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

get_subscription_sources() {
    local section="$1" urls url index disabled id errors
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || return 1
    urls="$(mktemp)" || return 1
    collect_subscription_urls "$section" "$urls" || { rm -f "$urls"; printf '[]\n'; return 0; }
    disabled="$(subscription_disabled_sources_json "$section")" || { rm -f "$urls"; return 1; }
    errors="$(cat "$(get_subscription_items_cache_path "$section").refresh-errors" 2>/dev/null || printf '{}')"
    index=0
    while IFS= read -r url || [ -n "$url" ]; do
        [ -n "$url" ] || continue
        index=$((index + 1))
        id="$(get_subscription_link_id "$url")"
        jq -cn --arg id "$id" --argjson index "$index" --argjson disabled "$disabled" --argjson errors "$errors" \
            '{id:$id,sourceIndex:$index,enabled:(($disabled | index($id)) == null),error:($errors[$id] // "")}'
    done < "$urls" | jq -s '.'
    rm -f "$urls"
}

subscription_source_error() {
    local section="$1" url="$2" code="$3" path id previous
    path="$(get_subscription_items_cache_path "$section").refresh-errors"
    id="$(get_subscription_link_id "$url")"
    previous="$(cat "$path" 2>/dev/null || printf '{}')"
    printf '%s\n' "$previous" | jq --arg id "$id" --arg code "$code" '.[$id]=$code' > "$path.tmp.$$" && mv "$path.tmp.$$" "$path"
}

subscription_items_with_sources() {
    local section="$1" file="$2" sources
    sources="$(get_subscription_sources "$section")" || return 1
    jq -c --argjson sources "$sources" '
        map(. as $item | .sourceIds = (.sourceIds // [$sources[] | select(.sourceIndex == ($item.sourceIndex // 1)) | .id]))
    ' "$file"
}

subscription_filter_source_links() {
    local items="$1" links="$2" output="$3" disabled="$4" excluded="$5" work link id
    local mode=all selected='[]' include='[]' exclude='[]' services='{"required":[],"results":[]}'
    if [ -n "${6:-}" ]; then
        mode="$(subscription_selection_mode "$6")"
        selected="$(subscription_selected_ids_json "$6")" || return 1
        include="$(subscription_tags_json "$6" subscription_include_tags)" || return 1
        exclude="$(subscription_tags_json "$6" subscription_exclude_tags)" || return 1
        if command -v subscription_services_policy >/dev/null 2>&1; then
            services="$(subscription_services_policy "$6")" || return 1
        fi
    fi
    work="$(mktemp)" || return 1
    subscription_source_policy "$disabled" "$excluded" "$items" "$mode" "$selected" "$include" "$exclude" "$services" > "$work" || { rm -f "$work"; return 1; }
    : > "$output"
    while IFS= read -r link || [ -n "$link" ]; do
        [ -n "$link" ] || continue
        id="$(get_subscription_link_id "$link")"
        if jq -e --arg id "$id" 'any(.[]; .id == $id and .runtimeEnabled)' "$work" >/dev/null; then
            printf '%s\n' "$link" >> "$output"
        fi
    done < "$links"
    mv "$work" "$items"
}

# Stage and validate source choices inside the existing single-commit transaction.
subscription_sources_prepare() {
    local section="$1" changes="$2" items="$3" excluded="$4" dir="$SUBSCRIPTION_APPLY_V2_TMP"
    local sources proposed id enabled current count mode=all selected='[]' include='[]' exclude='[]' required='[]' old_required='[]' services='{"required":[],"results":[]}'
    SUBSCRIPTION_SOURCES_ERROR=invalid_subscription_source
    sources="$(get_subscription_sources "$section")" || return 1
    proposed="$(subscription_disabled_sources_json "$section")"
    printf '%s\n' "$changes" | jq -r '.sources // [] | .[] | [.id,.enabled] | @tsv' > "$dir/sources.$section.changes" || return 1
    count=0
    if command -v subscription_services_policy >/dev/null 2>&1; then
        old_required="$(subscription_required_services_json "$section")" || return 1
        required="$(printf '%s' "$changes" | jq -c --argjson current "$old_required" '.requiredServices // $current')" || return 1
        subscription_services_validate "$required" || return 1
        if [ "$required" != '[]' ] && { ! command -v subscription_services_snapshot_capacity >/dev/null 2>&1 || ! subscription_services_snapshot_capacity; }; then
            SUBSCRIPTION_SOURCES_ERROR=service_snapshot_storage_unavailable
            return 1
        fi
        if [ "$required" != '[]' ] && command -v collect_urltest_proxy_links >/dev/null 2>&1 && collect_urltest_proxy_links "$section" "$dir/services.$section.manual" && [ -s "$dir/services.$section.manual" ]; then
            SUBSCRIPTION_SOURCES_ERROR=service_manual_links_unsupported
            return 1
        fi
        printf '%s\n' "$required" > "$dir/services.$section.required" || return 1
        [ "$required" = "$old_required" ] || count=$((count + 1))
        services="$(subscription_services_policy "$section" "$required")" || return 1
    elif printf '%s' "$changes" | jq -e 'has("requiredServices")' >/dev/null; then return 1; fi
    while IFS="$(printf '\t')" read -r id enabled; do
        [ -n "$id" ] || continue
        printf '%s\n' "$sources" | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null || return 1
        current="$(printf '%s\n' "$proposed" | jq --arg id "$id" 'index($id) != null')"
        [ "$current" = "$enabled" ] && count=$((count + 1))
        proposed="$(printf '%s\n' "$proposed" | jq -c --arg id "$id" --argjson enabled "$enabled" 'map(select(. != $id)) + (if $enabled then [] else [$id] end) | unique')" || return 1
    done < "$dir/sources.$section.changes"
    printf '%s\n' "$proposed" > "$dir/sources.$section.proposed"
    subscription_items_with_sources "$section" "$items" > "$dir/sources.$section.items" || return 1
    if [ -s "$dir/selection.$section.mode" ]; then
        mode="$(cat "$dir/selection.$section.mode")"
        selected="$(cat "$dir/selection.$section.ids")"
    fi
    include="$(cat "$dir/tags.$section.include")" || return 1
    exclude="$(cat "$dir/tags.$section.exclude")" || return 1
    subscription_source_policy "$proposed" "$excluded" "$dir/sources.$section.items" "$mode" "$selected" "$include" "$exclude" "$services" > "$dir/sources.$section.effective" || return 1
    SUBSCRIPTION_SOURCES_REMAINING="$(jq '[.[] | select(.runtimeEnabled)] | length' "$dir/sources.$section.effective")"
    if [ "$SUBSCRIPTION_SOURCES_REMAINING" -eq 0 ] && [ "$required" != '[]' ]; then
        SUBSCRIPTION_SOURCES_ERROR=service_no_eligible_nodes
        if printf '%s' "$services" | jq -e '.results|length==0' >/dev/null; then
            SUBSCRIPTION_SOURCES_ERROR=service_results_stale_or_missing
        fi
        return 1
    fi
    SUBSCRIPTION_SOURCES_CHANGED="$count"
}

subscription_sources_stage() {
    local section="$1" id
    if [ -s "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.required" ]; then
        local required current service
        required="$(cat "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.required")" || return 1
        current="$(subscription_required_services_json "$section")" || return 1
        if [ "$required" != "$current" ]; then
            subscription_cas_uci -q delete "podkop.$section.subscription_required_services" >/dev/null 2>&1 || true
            printf '%s' "$required" | jq -r '.[]' > "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.list" || return 1
            while IFS= read -r service; do
                subscription_cas_uci -q add_list "podkop.$section.subscription_required_services=$service" || return 1
            done < "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.list"
        fi
    fi
    # A link-only transaction must not alter another UCI option.
    [ -s "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.changes" ] || return 0
    subscription_cas_uci -q delete "podkop.$section.subscription_disabled_source_ids" >/dev/null 2>&1 || true
    jq -r '.[]' "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.proposed" > "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.ids" || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        subscription_cas_uci -q add_list "podkop.$section.subscription_disabled_source_ids=$id" || return 1
    done < "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.ids"
}

subscription_sources_verify() {
    local actual
    if [ -s "$SUBSCRIPTION_APPLY_V2_TMP/services.$1.required" ]; then
        [ "$(subscription_required_services_json "$1")" = "$(cat "$SUBSCRIPTION_APPLY_V2_TMP/services.$1.required")" ] || return 1
    fi
    actual="$(subscription_disabled_sources_json "$1")" || return 1
    [ "$actual" = "$(cat "$SUBSCRIPTION_APPLY_V2_TMP/sources.$1.proposed")" ]
}
# subscription_cas_v1 begin
# Content revisions describe semantic state, not historical identity (identical ABA).
# Reads only use private /tmp files. -t alone is NOT isolation: UCI retains its
# default delta search path. Absolute private-file operations disable deltas
# and conf2 overrides. Private paths must have no dots (UCI tuple syntax).
subscription_cas_sha256() {
    local digest
    digest="$(sha256sum "$1")" || return 1
    digest="${digest%% *}"
    case "$digest" in ''|*[!a-f0-9]*) return 1;; esac
    [ "${#digest}" = 64 ] || return 1
    printf '%s\n' "$digest"
}

subscription_cas_begin() {
    local dir="$1" dns
    SUBSCRIPTION_RESOURCE_ERROR=""
    dns="${PODKOP_SUBSCRIPTION_CAS_DNS_CONFIG:-/etc/sing-box/config.json}"
    # Admit the full input before any copy or JSON parsing, including runtime DNS.
    subscription_resource_bytes "$PODKOP_CONFIG" "$dns" || return 1
    subscription_resource_memory "$SUBSCRIPTION_RESOURCE_BYTES" 0 || return 1
    SUBSCRIPTION_CAS_DIR="$dir/cas"
    mkdir -m 700 "$SUBSCRIPTION_CAS_DIR" "$SUBSCRIPTION_CAS_DIR/config" "$SUBSCRIPTION_CAS_DIR/delta" || return 1
    SUBSCRIPTION_CAS_PACKAGE=podkop
    case "$SUBSCRIPTION_CAS_DIR" in *.*) return 1;; esac
    cp -p "$PODKOP_CONFIG" "$SUBSCRIPTION_CAS_DIR/base" &&
        cp -p "$SUBSCRIPTION_CAS_DIR/base" "$SUBSCRIPTION_CAS_DIR/config/$SUBSCRIPTION_CAS_PACKAGE" || return 1
    subscription_resource_bytes "$SUBSCRIPTION_CAS_DIR/base" || return 1
    subscription_resource_memory "$SUBSCRIPTION_RESOURCE_BYTES" 0 || return 1
    SUBSCRIPTION_CAS_DNS_PATH="$dns"
    if [ -e "$dns" ]; then
        subscription_cas_sha256 "$dns" > "$SUBSCRIPTION_CAS_DIR/dns.sha" || return 1
        jq -ceS '.dns | select(type=="object")' "$dns" > "$SUBSCRIPTION_CAS_DIR/dns-base.json" || return 1
    else
        printf 'absent\n' > "$SUBSCRIPTION_CAS_DIR/dns.sha"
        printf 'null\n' > "$SUBSCRIPTION_CAS_DIR/dns-base.json"
    fi
    SUBSCRIPTION_CAS_ACTIVE=1
    subscription_cas_config_load || return 1
    subscription_cas_config_json > "$SUBSCRIPTION_CAS_DIR/config.json"
}

subscription_cas_config_load() {
    local section name names
    # OpenWrt uci_load clears lists but leaves scalar variables for absent options.
    # Remove only the prior UCI sections' cached variables before committed reload.
    names="$(set | sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p')"
    for section in ${CONFIG_SECTIONS:-}; do
        case "$section" in ''|*[!A-Za-z0-9_]*) continue;; esac
        for name in $names; do
            case "$name" in CONFIG_${section}_*) unset "$name";; esac
        done
    done
    CONFIG_APPEND=""
    config_load "$SUBSCRIPTION_CAS_DIR/config/$SUBSCRIPTION_CAS_PACKAGE"
}

subscription_cas_uci() {
    local quiet='' operation key
    [ "${SUBSCRIPTION_CAS_ACTIVE:-0}" = 1 ] || { uci "$@"; return $?; }
    if [ "$1" = -q ]; then quiet=-q; shift; fi
    operation="$1"; key="${2:-}"; shift
    case "$key" in podkop) key="$SUBSCRIPTION_CAS_DIR/config/podkop";; podkop.*) key="$SUBSCRIPTION_CAS_DIR/config/podkop.${key#podkop.}";; *) return 1;; esac
    shift
    uci -c "$SUBSCRIPTION_CAS_DIR/config" -t "$SUBSCRIPTION_CAS_DIR/delta" ${quiet:+$quiet} "$operation" "$key" "$@"
}

subscription_cas_config_json() (
    # Parse UCI's safely quoted export, never source the raw configuration.
    # NUL records preserve embedded whitespace without one jq process per option.
    local data
    data="$(uci -q export "$SUBSCRIPTION_CAS_DIR/config/$SUBSCRIPTION_CAS_PACKAGE")" || exit 1
    package() { :; }
    config() { printf 'c\000%s\000%s\000' "$1" "$2"; }
    option() { printf 'o\000%s\000%s\000' "$1" "$2"; }
    list() { printf 'l\000%s\000%s\000' "$1" "$2"; }
    eval "$data" | jq -Rsc '
      split("\u0000") | .[:-1] | . as $a
      | reduce range(0; length; 3) as $i ({rows:{},section:null};
          if $a[$i]=="c" then .section=$a[$i+2] | .rows[.section]={".type":$a[$i+1]}
          elif $a[$i]=="o" then .rows[.section][$a[$i+1]]=$a[$i+2]
          elif $a[$i]=="l" then .rows[.section][$a[$i+1]]=((.rows[.section][$a[$i+1]]//[])+[$a[$i+2]])
          else error("invalid_export") end) | .rows'
)

subscription_cas_settings() {
    if [ "${SUBSCRIPTION_CAS_ACTIVE:-0}" = 1 ]; then
        subscription_cas_uci -q show podkop.settings > "$SUBSCRIPTION_CAS_DIR/settings.show" || return 1
        sed "s/^$SUBSCRIPTION_CAS_PACKAGE\\./podkop./" "$SUBSCRIPTION_CAS_DIR/settings.show"
    else uci -q show podkop.settings; fi
}

subscription_cas_environment_unchanged() {
    local hash=absent
    if [ -e "$SUBSCRIPTION_CAS_DNS_PATH" ]; then hash="$(subscription_cas_sha256 "$SUBSCRIPTION_CAS_DNS_PATH")" || return 1; fi
    [ "$hash" = "$(cat "$SUBSCRIPTION_CAS_DIR/dns.sha")" ]
}

subscription_cas_shared_clean() {
    local pending
    pending="$(uci -q changes podkop)" || return 1
    [ -z "$pending" ]
}

subscription_cas_publish() {
    local staged="${PODKOP_CONFIG}.subscription-cas.$$"
    subscription_cas_shared_clean || { SUBSCRIPTION_CAS_ERROR=uci_pending_changes; return 1; }
    subscription_cas_environment_unchanged || { SUBSCRIPTION_CAS_ERROR=revision_conflict; return 1; }
    # Cooperative mutations use our lock. An uncooperative writer is detected
    # before replacement; shell compare/rename cannot close that external race.
    cmp -s "$PODKOP_CONFIG" "$SUBSCRIPTION_CAS_DIR/base" || { SUBSCRIPTION_CAS_ERROR=revision_conflict; return 1; }
    cp -p "$SUBSCRIPTION_CAS_DIR/config/$SUBSCRIPTION_CAS_PACKAGE" "$staged" || { rm -f "$staged"; return 1; }
    if ! cmp -s "$PODKOP_CONFIG" "$SUBSCRIPTION_CAS_DIR/base"; then
        rm -f "$staged"; SUBSCRIPTION_CAS_ERROR=revision_conflict; return 1
    fi
    mv "$staged" "$PODKOP_CONFIG" || { rm -f "$staged"; return 1; }
}

subscription_section_revision() {
    local section="$1" dir="$SUBSCRIPTION_CAS_DIR" items all evidence dns
    [ "${SUBSCRIPTION_CAS_ACTIVE:-0}" = 1 ] || return 1
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || return 1
    jq -e --arg s "$section" '.[$s].connection_type=="proxy" and .[$s].proxy_config_type=="subscription_urltest"' "$dir/config.json" >/dev/null || return 1
    items="$(get_subscription_items_cache_path "$section")"; all="$(get_subscription_all_cache_path "$section")"
    evidence="$(subscription_services_cache_path "$section")"
    subscription_resource_bytes "$items" "$all" "$evidence" "$dir/config.json" || return 1
    subscription_resource_memory "$SUBSCRIPTION_RESOURCE_BYTES" 0 || return 1
    if [ -e "$items" ]; then cp "$items" "$dir/revision.items" || return 1
    else printf '[]\n' > "$dir/revision.items"; fi
    items="$dir/revision.items"
    jq -e --argjson max "$SUBSCRIPTION_RESOURCE_MAX_NODES" 'type=="array" and length<=$max and all(.[]; (.id|type=="string")) and ([.[].id]|length)==([.[].id]|unique|length)' "$items" >/dev/null || return 1
    subscription_resource_memory "$SUBSCRIPTION_RESOURCE_BYTES" "$(jq length "$items")" || return 1
    if [ -e "$evidence" ]; then
        jq -ceS 'select(type=="object" and (.results|type=="array")) | .results |= sort_by(.id)' "$evidence" > "$dir/evidence.json" || return 1
    else printf 'null\n' > "$dir/evidence.json"; fi
    subscription_cas_environment_unchanged || return 1
    if [ -e "$all" ]; then subscription_cas_sha256 "$all" > "$dir/links.sha" || return 1
    else printf 'absent\n' > "$dir/links.sha"; fi
    jq -cnS --arg section "$section" --slurpfile config "$dir/config.json" --slurpfile items "$items" \
        --slurpfile evidence "$dir/evidence.json" --slurpfile dns "$dir/dns-base.json" --rawfile links "$dir/links.sha" '
      def normalized: with_entries(if (.key|IN("subscription_selected_link_ids","subscription_excluded_link_ids","subscription_disabled_source_ids","subscription_include_tags","subscription_exclude_tags","subscription_required_services")) then .value |= (if type=="array" then unique else . end) else . end);
      {version:1,section:$section,policy:($config[0][$section]|normalized),
       settings:($config[0].settings|del(.shutdown_correctly,.subscription_isolated_section)),dns:$dns[0],
       items:($items[0]|map({id,selectionId,connectionKey,name,tag,supported,protocol,transport,sourceIndex,sourceIds:((.sourceIds//[])|unique)})|sort_by(.id)),
       links:$links,evidence:$evidence[0]}' > "$dir/revision.json" || return 1
    subscription_cas_sha256 "$dir/revision.json"
}

subscription_cas_snapshot_row() {
    local section="$1" dir="$SUBSCRIPTION_CAS_DIR" revision
    subscription_section_revision "$section" > "$dir/current.revision" || return 1
    revision="$(cat "$dir/current.revision")" || return 1
    get_subscription_sources "$section" > "$dir/sources.json" || return 1
    if ! get_subscription_services "$section" > "$dir/services.json"; then
        jq -cn --argjson required "$(subscription_required_services_json "$section")" '{success:false,requiredServices:$required,catalog:[],results:[]}' > "$dir/services.json" || return 1
    fi
    subscription_items_with_sources "$section" "$dir/revision.items" > "$dir/snapshot.items" || return 1
    local excluded_file="$dir/snapshot.excluded" excluded services
    collect_subscription_excluded_ids "$section" "$excluded_file" || return 1
    excluded="$(jq -Rsc 'split("\n")|map(select(length>0))' "$excluded_file")" || return 1
    services="$(jq -c '{required:.requiredServices,results:.results}' "$dir/services.json")" || return 1
    subscription_source_policy "$(subscription_disabled_sources_json "$section")" "$excluded" "$dir/snapshot.items" \
        "$(subscription_selection_mode "$section")" "$(subscription_selected_ids_json "$section")" \
        "$(subscription_tags_json "$section" subscription_include_tags)" "$(subscription_tags_json "$section" subscription_exclude_tags)" "$services" > "$dir/snapshot.effective" || return 1
    jq -cn --arg section "$section" --arg revision "$revision" --arg mode "$(subscription_selection_mode "$section")" --slurpfile config "$dir/config.json" \
        --slurpfile items "$dir/snapshot.effective" --slurpfile sources "$dir/sources.json" --slurpfile services "$dir/services.json" '
      def array: if type=="array" then . elif type=="string" then [.] else [] end;
      $config[0][$section] as $c | $services[0] as $s
      | ($s.results|map(. as $row|{key:.id,value:(.services|with_entries(.value += {checkedAt:(.value.checkedAt // $row.checkedAt),expiresAt:(.value.expiresAt // $row.expiresAt)}))})|from_entries) as $proofs
      | {code:$section,displayName:$section,revision:$revision,
         selectionMode:$mode,
         includeTags:($c.subscription_include_tags|array),excludeTags:($c.subscription_exclude_tags|array),communityLists:($c.community_lists|array),
         requiredServices:$s.requiredServices,serviceSupport:($s.success==true),serviceCatalog:$s.catalog,
         items:($items[0]|map(.+{services:($proofs[.id]//{})})),sources:$sources[0]}'
}

get_subscription_snapshot() (
    local dir section total=0 bytes
    if subscription_runtime_busy || ! subscription_action_lock_acquire subscription_snapshot; then
        subscription_apply_v2_print_result false error lock service_busy false false 0 false; exit 1
    fi
    dir="$(mktemp -d /tmp/podkop-subscription-snapshot-XXXXXX)" || { subscription_action_lock_release; exit 1; }
    trap 'rm -rf "$dir"; subscription_action_lock_release' EXIT
    trap 'exit 130' INT TERM HUP
    if ! subscription_cas_begin "$dir"; then
        subscription_apply_v2_print_result false error snapshot "${SUBSCRIPTION_RESOURCE_ERROR:-subscription_snapshot_failed}" false false 0 false; exit 1
    fi
    jq -r 'to_entries[]|select(.value.connection_type=="proxy" and .value.proxy_config_type=="subscription_urltest")|.key' "$SUBSCRIPTION_CAS_DIR/config.json" > "$dir/sections" || exit 1
    : > "$dir/rows"
    while IFS= read -r section; do
        bytes=0
        if [ -f "$(get_subscription_items_cache_path "$section")" ]; then
            bytes="$(wc -c < "$(get_subscription_items_cache_path "$section")")" || exit 1
        fi
        total=$((total + bytes))
        if ! subscription_resource_memory "$total" 0; then
            subscription_apply_v2_print_result false error snapshot "$SUBSCRIPTION_RESOURCE_ERROR" false false 0 false; exit 1
        fi
        if ! subscription_cas_snapshot_row "$section" >> "$dir/rows"; then
            subscription_apply_v2_print_result false error snapshot "${SUBSCRIPTION_RESOURCE_ERROR:-subscription_snapshot_failed}" false false 0 false; exit 1
        fi
    done < "$dir/sections"
    subscription_cas_environment_unchanged && cmp -s "$PODKOP_CONFIG" "$SUBSCRIPTION_CAS_DIR/base" || { subscription_apply_v2_print_result false error snapshot revision_conflict false false 0 false; exit 1; }
    jq -cs '{success:true,version:1,sections:.}' "$dir/rows"
)
# subscription_cas_v1 end
# subscription_sources_v1 end
