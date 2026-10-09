# subscription_sources_v1 begin
# A source is identified by its URL hash, never by its position in the UI.
# subscription_source_actions_v1
# subscription_choices_and_busy_v1
# subscription_selection_v1
# subscription_tag_filters_v1
# subscription_tag_glob_portable_v1
# subscription_service_filter_v1
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
        uci -q delete "podkop.$section.subscription_${option}_tags" >/dev/null 2>&1 || true
        printf '%s' "$proposed" | jq -r '.[]' > "$SUBSCRIPTION_APPLY_V2_TMP/tags.$section.$option.list" || return 1
        while IFS= read -r value; do
            uci -q add_list "podkop.$section.subscription_${option}_tags=$value" || return 1
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
        uci -q set "podkop.$section.subscription_selection_mode=$mode" || return 1
    fi
    [ "$mode" = selected ] || return 0
    uci -q delete "podkop.$section.subscription_selected_link_ids" >/dev/null 2>&1 || true
    jq -r '.[]' "$dir/selection.$section.ids" > "$dir/selection.$section.list" || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        uci -q add_list "podkop.$section.subscription_selected_link_ids=$id" || return 1
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
          def same_key($a;$b): ($a.connectionKey // "") != "" and $a.connectionKey == $b.connectionKey;
          def same_name($a;$b): ($a.name // "") != "" and $a.name==$b.name and $a.protocol==$b.protocol and ($a.transport // "")==($b.transport // "");
          map(. as $item
            | [$old[0][] | select(.id==$item.id)] as $exact
            | [$old[0][] | select(same_source(.;$item) and same_key(.;$item))] as $key
            | [$old[0][] | select(same_source(.;$item) and same_name(.;$item))] as $name
            | (if ($exact|length)==1 then $exact[0]
               elif ($key|length)==1 and ([$new[]|select(same_source(.;$item) and same_key(.;$item))]|length)==1 then $key[0]
               elif ($name|length)==1 and ([$new[]|select(same_source(.;$item) and same_name(.;$item))]|length)==1 then $name[0]
               else null end) as $previous
            | .selectionId=($previous.selectionId // $previous.id // .id)
            | .selectionNew=($previous==null and ($old[0]|length)>0))
    ' "$2"
}

get_subscription_operation_status() {
    local busy=false pending=false
    subscription_runtime_busy && busy=true
    [ ! -f "$(subscription_reload_pending_file)" ] || pending=true
    jq -cn --argjson busy "$busy" --argjson pending "$pending" \
        '{busy:$busy,pending:$pending,retryAfter:3,reason:(if $busy then "service_busy" else "" end)}'
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
    printf '%s\n' "$services" | jq -c --argjson disabled "$1" --argjson excluded "$2" --arg mode "${4:-all}" --argjson selected "${5:-[]}" \
        --argjson include "${6:-[]}" --argjson exclude "${7:-[]}" --slurpfile policy_items "$3" '
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
        def leading_code($code; $name):
            ($name | startswith($code)) and
            (($name | length) == 2 or ([" ","\t","\n","\r","\f",".","_",":","/","-"] | index($name[2:3]) != null));
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
            | if ($pattern | startswith("@prefix:")) and (country_code($pattern[8:]) != null)
              then prefix_matches($pattern[8:]; $name)
              elif $legacy_code != null then prefix_matches($legacy_code; $name)
              else glob_matches($pattern; $name) end;
        def matches($patterns; $name): any($patterns[]; pattern_matches(.; $name));
        map(. as $item
            | .enabled = (.supported == true and (if $mode=="selected" then
                ($selected | index($item.selectionId // $item.id)) != null
                elif $mode=="all" then ($excluded | index($item.id)) == null and ($excluded | index($item.selectionId // $item.id)) == null
                else true end))
            | .sourceEnabled = (if ((.sourceIds // []) | length) > 0 then
                any(.sourceIds[]; . as $id | ($disabled | index($id)) == null)
                else ($disabled | length) == 0 end)
            | .tagExcluded = ((($include|length)>0 and (matches($include; $item.name // $item.tag // "")|not)) or matches($exclude; $item.name // $item.tag // ""))
            | .serviceExcluded = (all($services.required[]; . as $service | $service_status[$item.id][$service].state=="pass") | not)
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
    SUBSCRIPTION_SOURCES_CHANGED="$count"
}

subscription_sources_stage() {
    local section="$1" id
    if [ -s "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.required" ]; then
        local required current service
        required="$(cat "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.required")" || return 1
        current="$(subscription_required_services_json "$section")" || return 1
        if [ "$required" != "$current" ]; then
            uci -q delete "podkop.$section.subscription_required_services" >/dev/null 2>&1 || true
            printf '%s' "$required" | jq -r '.[]' > "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.list" || return 1
            while IFS= read -r service; do
                uci -q add_list "podkop.$section.subscription_required_services=$service" || return 1
            done < "$SUBSCRIPTION_APPLY_V2_TMP/services.$section.list"
        fi
    fi
    # A link-only transaction must not alter another UCI option.
    [ -s "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.changes" ] || return 0
    uci -q delete "podkop.$section.subscription_disabled_source_ids" >/dev/null 2>&1 || true
    jq -r '.[]' "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.proposed" > "$SUBSCRIPTION_APPLY_V2_TMP/sources.$section.ids" || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        uci -q add_list "podkop.$section.subscription_disabled_source_ids=$id" || return 1
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
# subscription_sources_v1 end
