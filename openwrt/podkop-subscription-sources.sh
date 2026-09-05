# subscription_sources_v1 begin
# A source is identified by its URL hash, never by its position in the UI.
# subscription_source_actions_v1
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
    jq -c --argjson disabled "$1" --argjson excluded "$2" '
        map(. as $item
            | .enabled = (.supported == true and ($excluded | index($item.id)) == null)
            | .sourceEnabled = (if ((.sourceIds // []) | length) > 0 then
                any(.sourceIds[]; . as $id | ($disabled | index($id)) == null)
                else ($disabled | length) == 0 end)
            | .runtimeEnabled = (.enabled and .sourceEnabled)
            | if .supported then .reason = (if .enabled then "" else "user_excluded" end) else . end)
    ' "$3"
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
    work="$(mktemp)" || return 1
    subscription_source_policy "$disabled" "$excluded" "$items" > "$work" || { rm -f "$work"; return 1; }
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
    local sources proposed id enabled current count
    sources="$(get_subscription_sources "$section")" || return 1
    proposed="$(subscription_disabled_sources_json "$section")"
    printf '%s\n' "$changes" | jq -r '.sources // [] | .[] | [.id,.enabled] | @tsv' > "$dir/sources.$section.changes" || return 1
    count=0
    while IFS="$(printf '\t')" read -r id enabled; do
        [ -n "$id" ] || continue
        printf '%s\n' "$sources" | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null || return 1
        current="$(printf '%s\n' "$proposed" | jq --arg id "$id" 'index($id) != null')"
        [ "$current" = "$enabled" ] && count=$((count + 1))
        proposed="$(printf '%s\n' "$proposed" | jq -c --arg id "$id" --argjson enabled "$enabled" 'map(select(. != $id)) + (if $enabled then [] else [$id] end) | unique')" || return 1
    done < "$dir/sources.$section.changes"
    printf '%s\n' "$proposed" > "$dir/sources.$section.proposed"
    subscription_items_with_sources "$section" "$items" > "$dir/sources.$section.items" || return 1
    subscription_source_policy "$proposed" "$excluded" "$dir/sources.$section.items" > "$dir/sources.$section.effective" || return 1
    SUBSCRIPTION_SOURCES_REMAINING="$(jq '[.[] | select(.runtimeEnabled)] | length' "$dir/sources.$section.effective")"
    SUBSCRIPTION_SOURCES_CHANGED="$count"
}

subscription_sources_stage() {
    local section="$1" id
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
    actual="$(subscription_disabled_sources_json "$1")" || return 1
    [ "$actual" = "$(cat "$SUBSCRIPTION_APPLY_V2_TMP/sources.$1.proposed")" ]
}
# subscription_sources_v1 end
