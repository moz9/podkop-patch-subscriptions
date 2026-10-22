# subscription_service_snapshot_v1 begin
# Preserve one exact, already-admitted runtime. This is not fresh service evidence.
subscription_services_snapshot_dir() {
    printf '%s\n' "${PODKOP_SERVICE_SNAPSHOT_DIR:-/etc/podkop/subscriptions/service-runtime}"
}

subscription_services_snapshot_hash() {
    local digest snapshot_config_path
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    if command -v podkop_section_enabled >/dev/null && podkop_section_enabled; then
        config_get snapshot_config_path settings config_path
        if [ "$1" = "$snapshot_config_path" ]; then
            podkop_section_runtime_hash "$1"
            return $?
        fi
    fi
    digest="$(sha256sum "$1")" || return 1
    digest="${digest%% *}"
    [ "${#digest}" = 64 ] || return 1
    case "$digest" in *[!a-f0-9]*) return 1;; esac
    printf '%s\n' "$digest"
}

subscription_services_snapshot_policy_hash() {
    local policy
    if [ -n "${PODKOP_DNS_COMMITTED_FILE:-}" ]; then
        policy="$(uci -q export /proc/self/fd/3 3< "$PODKOP_DNS_COMMITTED_FILE")" || return 1
        policy="$(printf '%s\n' "$policy" | sed 's/^package 3$/package podkop/')"
    else policy="$(uci -q export podkop)" || return 1; fi
    [ -n "$policy" ] || return 1
    # Only this operational field changes during normal start/stop.
    printf '%s\n' "$policy" | awk '/^config / {settings=($2=="settings")} !(settings && $1=="option" && $2=="shutdown_correctly")' | sha256sum | awk '{print $1}'
}

subscription_services_snapshot_enabled_section() {
    validate_subscription_urltest_section "$1" || return 0
    [ "$(subscription_required_services_json "$1")" = '[]' ] || SNAPSHOT_HAS_REQUIRED=1
}

subscription_services_snapshot_unfiltered() {
    # An empty receipt admits no nodes. With no selected service filters it
    # must not turn an old graph hash into a mandatory service requirement.
    local dir SNAPSHOT_HAS_REQUIRED=0
    config_foreach subscription_services_snapshot_enabled_section section
    [ "$SNAPSHOT_HAS_REQUIRED" = 0 ] || return 1
    dir="$(subscription_services_snapshot_dir)"
    [ -f "$dir/snapshot.json" ] && [ ! -L "$dir" ] && [ ! -L "$dir/snapshot.json" ] || return 1
    jq -e '.version==1 and .sections==[]
        and (.config|type=="string" and length==64)
        and (.rules|type=="array" and length<=128)
        and all(.rules[]; (.name|type=="string") and (.sha|type=="string" and length==64))' \
        "$dir/snapshot.json" >/dev/null 2>&1
}

subscription_services_restart_prepare() {
    # Service/config-triggered restarts are not permission to apply new pools.
    # Explicit apply keeps its fresh-evidence gate and transactional workflow.
    PODKOP_SERVICE_RESTART_CONTINUITY=0
    SNAPSHOT_HAS_REQUIRED=0
    config_foreach subscription_services_snapshot_enabled_section section
    if [ "${PODKOP_SUBSCRIPTION_APPLY_NOW:-0}" != 1 ] &&
       { [ "$SNAPSHOT_HAS_REQUIRED" = 1 ] ||
         { { [ -e "$(subscription_services_snapshot_dir)/snapshot.json" ] ||
             [ -L "$(subscription_services_snapshot_dir)/snapshot.json" ]; } &&
           ! subscription_services_snapshot_unfiltered; }; }; then
        subscription_services_continuity_context_ready || return 1
        subscription_services_snapshot_continuity_prepare || return 1
        PODKOP_SERVICE_RESTART_CONTINUITY=1
        return 0
    fi
    subscription_services_preflight
}

subscription_config_apply() (
    local stamp policy pending
    stamp="${PODKOP_CONFIG_APPLY_STAMP:-/tmp/podkop-config-applied.sha256}"
    if subscription_runtime_busy || ! subscription_action_lock_acquire config_apply; then
        log 'Configuration apply deferred: another operation is running' warn
        return 1
    fi
    trap 'subscription_action_lock_release' EXIT
    trap 'exit 1' HUP INT TERM
    pending="$(uci -q changes podkop)" || return 1
    [ -z "$pending" ] || { log 'Configuration apply refused: unsaved UCI changes' warn; return 1; }
    policy="$(subscription_services_snapshot_policy_hash)" || return 1
    [ ! -L "$stamp" ] && [ ! -L "$stamp.tmp.$" ] || return 1
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$policy" ]; then return 0; fi
    # The restart itself validates evidence before its first destructive step.
    # No subscription download, second engine, or broad UCI revert is involved.
    if ! PODKOP_SUBSCRIPTION_APPLY_NOW=1 PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 restart; then
        log 'Configuration apply failed; no successful apply receipt was recorded' err
        return 1
    fi
    # shutdown_correctly is excluded by this policy hash; any other concurrent
    # change must not receive a receipt for the configuration we just applied.
    [ "$(subscription_services_snapshot_policy_hash)" = "$policy" ] || return 1
    (umask 077; printf '%s\n' "$policy" > "$stamp.tmp.$") && mv "$stamp.tmp.$" "$stamp"
)

subscription_services_continuity_context_ready() {
    local expected actual
    if command -v podkop_section_enabled >/dev/null && podkop_section_enabled; then
        if command -v podkop_section_context_matches >/dev/null && podkop_section_context_matches; then return 0; fi
        # v2 excludes documented selection/diagnostic drafts, but retains all
        # traffic-affecting settings. Only exact applied context may restart.
        expected="$(cat "$(podkop_section_root)/context.sha256" 2>/dev/null)" || return 1
        case "$expected" in v2:*) [ "${#expected}" = 67 ] || return 1;; *) return 1;; esac
        actual="$(podkop_section_context_hash)" || return 1
        [ "$expected" = "$actual" ] || {
            log 'Saved runtime traffic context differs from desired settings; keeping the running service unchanged' warn
            return 1
        }
    fi
}

subscription_services_snapshot_capacity() (
    local dir config_path paths path name size total=0 count=0 free_kb
    config_get config_path settings config_path
    [ -s "$config_path" ] || exit 1
    dir="$(subscription_services_snapshot_dir)"
    umask 077
    [ ! -L "$dir" ] || exit 1
    mkdir -p "$dir" && chmod 700 "$dir" || exit 1
    [ ! -L "$dir" ] || exit 1
    paths="$(mktemp)" || exit 1
    trap 'rm -f "$paths"' EXIT INT TERM HUP
    jq -r '[.route.rule_set[]? | select(.type=="local") | .path] | unique[]' "$config_path" > "$paths" || exit 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        name="${path#"$TMP_RULESET_FOLDER/"}"
        case "$name" in ''|.|..|*[!A-Za-z0-9_.-]*) exit 1;; esac
        case "$name" in *.json|*.srs) ;; *) exit 1;; esac
        [ "$path" = "$TMP_RULESET_FOLDER/$name" ] && [ -f "$path" ] && [ ! -L "$path" ] || exit 1
        size="$(wc -c < "$path")"; total=$((total + size)); count=$((count + 1))
        [ "$total" -le 25165824 ] && [ "$count" -le 128 ] || exit 1
    done < "$paths"
    free_kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
    case "$free_kb" in ''|*[!0-9]*) exit 1;; esac
    [ "$free_kb" -ge $(((total + 1023)/1024 + 1024)) ]
)

subscription_services_snapshot_observations() {
    local section="$1" ids="$2" row expected current required
    if [ "${SNAPSHOT_CAPTURE:-1}" != 1 ] &&
        jq -e --arg s "$section" '.sections[]|select(.section==$s)|has("evidence")' "$SNAPSHOT_BASE" >/dev/null; then
        row="$(jq -cS --arg s "$section" '.sections[]|select(.section==$s)|.evidence|sort_by(.id)' "$SNAPSHOT_BASE")" || return 1
        expected="$(jq -er --arg s "$section" '.sections[]|select(.section==$s)|.service' "$SNAPSHOT_BASE")" || return 1
        [ "$(printf '%s\n' "$row" | sha256sum | awk '{print $1}')" = "$expected" ] || return 1
        # Strict reuse still honors a current definitive denial. Expiry,
        # eviction and unknown observations do not revoke frozen admission.
        if command -v subscription_services_read >/dev/null 2>&1; then
            current="$(subscription_services_read "$section")" || return 1
        elif [ -s "$(subscription_services_cache_path "$section")" ]; then
            current="$(jq -c '.results//[]' "$(subscription_services_cache_path "$section")")" || return 1
        else current='[]'; fi
        required="$(jq -c --arg s "$section" '.sections[]|select(.section==$s)|.requiredServices//[]' "$SNAPSHOT_BASE")" || return 1
        [ "$required" != '[]' ] || required="$(subscription_required_services_json "$section")" || return 1
        printf '%s' "$current" | jq -e --argjson ids "$ids" --argjson required "$required" '
          all(.[]; if (.id as $id|$ids|index($id)!=null) then
            . as $r | all($required[]; . as $s | $r.services[$s].state!="fail")
          else true end)' >/dev/null || return 1
        printf '%s\n' "$row"
    else
        if command -v subscription_services_cache_raw >/dev/null 2>&1; then
            subscription_services_cache_raw "$section"
        else
            cat "$(subscription_services_cache_path "$section")"
        fi | jq -cS --argjson ids "$ids" '[.results[]? | select(.id as $id | $ids|index($id)!=null)] | sort_by(.id)'
    fi
}

subscription_services_snapshot_section_value() (
    local section="$1" required cache all items context service_sha link id ids='[]' links='[]' hash policy row evidence
    local work manual manual_ids='[]' input
    validate_subscription_urltest_section "$section" || return 0
    required="$(subscription_required_services_json "$section")" || return 1
    [ "$required" != '[]' ] || return 0
    cache="$(get_subscription_cache_path "$section")"
    all="$(get_subscription_all_cache_path "$section")"
    items="$(get_subscription_items_cache_path "$section")"
    [ -s "$cache" ] && [ -s "$all" ] && [ -s "$items" ] || return 1
    work="$(mktemp -d)" || return 1
    trap 'rm -rf "$work"' EXIT INT TERM HUP
    manual="$work/manual"
    : > "$manual"
    if command -v subscription_services_manual_file >/dev/null 2>&1; then
        subscription_services_manual_file "$section" "$manual" || return 1
    fi
    while IFS= read -r link || [ -n "$link" ]; do
        [ -n "$link" ] || continue
        id="$(get_subscription_link_id "$link")" || return 1
        manual_ids="$(printf '%s' "$manual_ids" | jq -c --arg id "$id" '.+[$id]|unique')" || return 1
    done < "$manual"
    context="$(subscription_services_context "$section")" || return 1
    [ -n "$context" ] || return 1
    if [ "$SNAPSHOT_CAPTURE" = 1 ]; then
        policy="$(subscription_services_policy "$section")" || return 1
        for input in "$cache" "$manual"; do
        while IFS= read -r link || [ -n "$link" ]; do
            [ -n "$link" ] || continue
            id="$(get_subscription_link_id "$link")" || return 1
            printf '%s' "$policy" | jq -e --arg id "$id" '. as $p | all($p.required[]; . as $service | any($p.results[]; .id==$id and .services[$service].state=="pass"))' >/dev/null || return 1
            ids="$(printf '%s' "$ids" | jq -c --arg id "$id" '.+[$id] | unique')" || return 1
        done < "$input"
        done
        [ "$ids" != '[]' ] || return 1
    else
        ids="$(jq -c --arg section "$section" '.sections[] | select(.section==$section) | .admittedIds' "$SNAPSHOT_BASE")" || return 1
        printf '%s' "$ids" | jq -e 'type=="array" and length>0' >/dev/null || return 1
    fi
    # Bind exact admitted links and their evidence, not unrelated newly discovered nodes.
    jq -e --argjson ids "$ids" --argjson manual "$manual_ids" '. as $items | all($ids[]; . as $id | ($manual|index($id)!=null) or any($items[]; .id==$id and .supported==true))' "$items" >/dev/null || return 1
    for input in "$all" "$manual"; do
    while IFS= read -r link || [ -n "$link" ]; do
        [ -n "$link" ] || continue
        id="$(get_subscription_link_id "$link")" || return 1
        printf '%s' "$ids" | jq -e --arg id "$id" 'index($id)!=null' >/dev/null || continue
        hash="$(printf '%s\n' "$link" | sha256sum | awk '{print $1}')"
        links="$(printf '%s' "$links" | jq -c --arg id "$id" --arg sha "$hash" '.+[{id:$id,sha:$sha}] | unique_by(.id) | sort_by(.id)')" || return 1
    done < "$input"
    done
    [ "$(printf '%s' "$links" | jq -c 'map(.id)|sort')" = "$(printf '%s' "$ids" | jq -c 'sort')" ] || return 1
    row="$(subscription_services_snapshot_observations "$section" "$ids")" || return 1
    [ "$(printf '%s' "$row" | jq -c 'map(.id)|sort')" = "$(printf '%s' "$ids" | jq -c 'sort')" ] || return 1
    service_sha="$(printf '%s\n' "$row" | sha256sum | awk '{print $1}')"
    evidence=null
    if [ "$SNAPSHOT_CAPTURE" = 1 ] || jq -e --arg s "$section" '.sections[]|select(.section==$s)|has("evidence")' "$SNAPSHOT_BASE" >/dev/null; then evidence="$row"; fi
    printf '%s\n%s\n' "$links" "${evidence:-null}" | jq -cs --arg section "$section" --arg context "$context" --arg service "$service_sha" --argjson required "$required" \
        '.[0] as $links | .[1] as $evidence | {section:$section,context:$context,service:$service,requiredServices:$required,admittedIds:($links|map(.id)),admittedLinks:$links} + (if $evidence==null then {} else {evidence:$evidence} end)'
)

subscription_services_snapshot_section() {
    local row
    row="$(subscription_services_snapshot_section_value "$1")" || { SNAPSHOT_FAILED=1; return 0; }
    [ -z "$row" ] || printf '%s\n' "$row" >> "$SNAPSHOT_SECTIONS" || SNAPSHOT_FAILED=1
}

subscription_services_snapshot_save() (
    # Call only after successful generation AND runtime readiness, never while rolling back.
    SNAPSHOT_HAS_REQUIRED=0
    config_foreach subscription_services_snapshot_enabled_section section
    [ "$SNAPSHOT_HAS_REQUIRED" = 1 ] || exit 0
    subscription_services_preflight && subscription_sing_box_reload_ready || exit 1
    local config_path config_sha policy_sha dir work previous path name hash size free_kb snapshot_tmp='' total=0 count=0
    config_get config_path settings config_path
    config_sha="$(subscription_services_snapshot_hash "$config_path")" && policy_sha="$(subscription_services_snapshot_policy_hash)" || exit 1
    sing-box check -c "$config_path" >/dev/null 2>&1 || exit 1
    SNAPSHOT_SECTIONS="$(mktemp)" || exit 1
    work=''
    trap 'rm -f "$SNAPSHOT_SECTIONS"; [ -z "$snapshot_tmp" ] || rm -f "$snapshot_tmp"; [ -z "$work" ] || rm -rf "$work"' EXIT INT TERM HUP
    SNAPSHOT_FAILED=0; SNAPSHOT_CAPTURE=1
    config_foreach subscription_services_snapshot_section section
    [ "$SNAPSHOT_FAILED" = 0 ] || exit 1
    [ -s "$SNAPSHOT_SECTIONS" ] || exit 0
    dir="$(subscription_services_snapshot_dir)"
    umask 077
    [ ! -L "$dir" ] || exit 1
    mkdir -p "$dir" && chmod 700 "$dir" || exit 1
    [ ! -L "$dir" ] || exit 1
    work="$(mktemp -d "$dir/generation.XXXXXX")" || exit 1
    jq -r '[.route.rule_set[]? | select(.type=="local") | .path] | unique[]' "$config_path" > "$work/paths" || exit 1
    : > "$work/rules"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        name="${path#"$TMP_RULESET_FOLDER/"}"
        case "$name" in ''|.|..|*[!A-Za-z0-9_.-]*) exit 1;; esac
        case "$name" in *.json|*.srs) ;; *) exit 1;; esac
        [ "$path" = "$TMP_RULESET_FOLDER/$name" ] || exit 1
        hash="$(subscription_services_snapshot_hash "$path")" || exit 1
        size="$(wc -c < "$path")"; total=$((total + size))
        count=$((count + 1))
        [ "$total" -le 25165824 ] && [ "$count" -le 128 ] || exit 1
        jq -cn --arg name "$name" --arg hash "$hash" '{name:$name,sha:$hash}' >> "$work/rules" || exit 1
    done < "$work/paths"
    free_kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
    case "$free_kb" in ''|*[!0-9]*) exit 1;; esac
    [ "$free_kb" -ge $(((total + 1023)/1024 + 1024)) ] || exit 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        name="${path##*/}"
        hash="$(jq -r --arg name "$name" 'select(.name==$name)|.sha' "$work/rules")"
        cp "$path" "$work/$name" && chmod 600 "$work/$name" || exit 1
        [ "$(subscription_services_snapshot_hash "$work/$name")" = "$hash" ] || exit 1
    done < "$work/paths"
    snapshot_tmp="$dir/snapshot.tmp.$$"
    [ ! -L "$snapshot_tmp" ] || exit 1
    jq -cn --arg config "$config_sha" --arg policy "$policy_sha" --arg generation "${work##*/}" --slurpfile sections "$SNAPSHOT_SECTIONS" --slurpfile rules "$work/rules" \
        '{version:1,config:$config,policy:$policy,generation:$generation,sections:$sections,rules:$rules}' > "$snapshot_tmp" || exit 1
    chmod 600 "$snapshot_tmp" || exit 1
    previous="$(jq -r '.generation // ""' "$dir/snapshot.json" 2>/dev/null || true)"
    mv "$snapshot_tmp" "$dir/snapshot.json" || exit 1
    snapshot_tmp=''
    work=''
    case "$previous" in generation.*) case "${previous#generation.}" in ''|*[!A-Za-z0-9]*) ;; *) [ -L "$dir/$previous" ] || rm -rf "$dir/$previous";; esac;; esac
)

subscription_services_snapshot_section_traffic_context() (
    local checkpoint desired root
    command -v podkop_section_context_hash >/dev/null 2>&1 || exit 1
    root="${PODKOP_SECTION_ROOT:-/etc/podkop/section-runtime}"
    [ ! -L "$root" ] && [ ! -L "$root/context.sha256" ] || exit 1
    checkpoint="$(cat "$root/context.sha256")" && desired="$(podkop_section_context_hash)" || exit 1
    case "$checkpoint:$desired" in v2:*:v2:*) :;; *) exit 1;; esac
    [ "${#checkpoint}" = 67 ] && [ "${#desired}" = 67 ] || exit 1
    case "${checkpoint#v2:}${desired#v2:}" in *[!a-f0-9]*) exit 1;; esac
    jq -cn --arg checkpoint "$checkpoint" --arg desired "$desired" '{checkpoint:$checkpoint,desired:$desired}'
)

subscription_services_snapshot_section_stage() (
    # Structural manager isolation is required separately. Never capture peers or
    # claim that pending shared UCI settings were applied by a worker-only apply.
    local target="$1" work="$2" dir manifest config_path config_sha name hash generation
    case "$target" in ''|*[!A-Za-z0-9_]*) exit 1;; esac
    [ -d "$work" ] && [ ! -L "$work" ] || exit 1
    dir="$(subscription_services_snapshot_dir)"; manifest="$dir/snapshot.json"
    [ ! -L "$manifest" ] && [ ! -L "$dir" ] || exit 1
    if [ ! -e "$manifest" ]; then
        SNAPSHOT_HAS_REQUIRED=0
        config_foreach subscription_services_snapshot_enabled_section section
        [ "$SNAPSHOT_HAS_REQUIRED" = 0 ] || exit 1
        : > "$work/snapshot-unfiltered"
        exit 0
    fi
    [ -s "$manifest" ] || exit 1
    # Bind saved intent to this isolated transaction without claiming it was
    # globally applied. DNS-only successors may preserve this exact graph.
    if command -v podkop_section_context_hash >/dev/null 2>&1; then
        subscription_services_snapshot_section_traffic_context > "$work/snapshot-traffic-context" || rm -f "$work/snapshot-traffic-context"
    fi
    config_get config_path settings config_path
    config_sha="$(subscription_services_snapshot_hash "$config_path")" || exit 1
    # A stale compound hash can be reconstructed only when this target is the
    # sole required-service admission. There are then no unknown peers to bless.
    SNAPSHOT_SECTIONS="$work/required-sections.jsonl"; : > "$SNAPSHOT_SECTIONS"
    SNAPSHOT_FAILED=0
    config_foreach subscription_services_snapshot_continuity_section section
    [ "$SNAPSHOT_FAILED" = 0 ] || exit 1
    jq -e --arg sha "$config_sha" --arg target "$target" --slurpfile required "$SNAPSHOT_SECTIONS" '
        .version==1 and (.config==$sha or (all($required[]; .==$target) and all(.sections[]; .section==$target)))
        and (.sections|type=="array") and (.rules|type=="array" and length<=128)
        and (.sections|map(.section)|length==(unique|length))
        and (.rules|map(.name)|length==(unique|length))' "$manifest" >/dev/null || exit 1
    jq -e --arg folder "$TMP_RULESET_FOLDER/" --slurpfile saved "$manifest" '
        [.route.rule_set[]? | select(.type=="local") | .path] | unique | sort
        == ($saved[0].rules | map($folder+.name) | sort)' "$config_path" >/dev/null || exit 1
    generation="$(jq -r '.generation' "$manifest")"
    case "$generation" in generation.*) case "${generation#generation.}" in ''|*[!A-Za-z0-9]*) exit 1;; esac;; *) exit 1;; esac
    [ ! -L "$dir/$generation" ] && [ ! -L "$TMP_RULESET_FOLDER" ] || exit 1
    jq -r '.rules[] | [.name,.sha] | @tsv' "$manifest" > "$work/snapshot-rules" || exit 1
    while IFS="$(printf '\t')" read -r name hash; do
        case "$name" in ''|.|..|*[!A-Za-z0-9_.-]*) exit 1;; esac
        [ "$(subscription_services_snapshot_hash "$dir/$generation/$name")" = "$hash" ] &&
        [ "$(subscription_services_snapshot_hash "$TMP_RULESET_FOLDER/$name")" = "$hash" ] || exit 1
    done < "$work/snapshot-rules"
    cp "$manifest" "$work/snapshot-base.json" || exit 1
    SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=0
    subscription_services_preflight_section "$target"
    [ "$SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED" = 0 ] || exit 1
    SNAPSHOT_SECTIONS="$work/snapshot-target.jsonl"
    : > "$SNAPSHOT_SECTIONS"
    SNAPSHOT_FAILED=0; SNAPSHOT_CAPTURE=1
    subscription_services_snapshot_section "$target"
    [ "$SNAPSHOT_FAILED" = 0 ] || exit 1
)

subscription_services_snapshot_section_commit() (
    local target="$1" work="$2" dir config_path config_sha tmpfile name hash traffic=null
    dir="$(subscription_services_snapshot_dir)"
    if [ -f "$work/snapshot-unfiltered" ]; then
        [ ! -e "$dir/snapshot.json" ] && [ ! -L "$dir/snapshot.json" ] || exit 1
        exit 0
    fi
    cmp -s "$work/snapshot-base.json" "$dir/snapshot.json" || exit 1
    if [ -e "$work/snapshot-traffic-context" ]; then
        [ ! -L "$work/snapshot-traffic-context" ] || exit 1
        traffic="$(subscription_services_snapshot_section_traffic_context)" || exit 1
        [ "$traffic" = "$(cat "$work/snapshot-traffic-context")" ] || exit 1
    fi
    subscription_sing_box_reload_ready || exit 1
    config_get config_path settings config_path
    config_sha="$(subscription_services_snapshot_hash "$config_path")" || exit 1
    sing-box check -c "$config_path" >/dev/null 2>&1 || exit 1
    while IFS="$(printf '\t')" read -r name hash; do
        [ "$(subscription_services_snapshot_hash "$TMP_RULESET_FOLDER/$name")" = "$hash" ] || exit 1
    done < "$work/snapshot-rules"
    tmpfile="$(mktemp "$dir/snapshot.section.XXXXXX")" || exit 1
    trap 'rm -f "$tmpfile"' EXIT INT TERM HUP
    jq --arg target "$target" --arg config "$config_sha" --argjson traffic "$traffic" --slurpfile row "$work/snapshot-target.jsonl" '
        .config=$config | .sections=((.sections|map(select(.section!=$target)))+$row|sort_by(.section))
        | .continuity=({mode:"section-only",section:$target} +
          (if $traffic==null then {} else {trafficContext:$traffic} end))' "$work/snapshot-base.json" > "$tmpfile" || exit 1
    chmod 600 "$tmpfile" || exit 1
    cmp -s "$work/snapshot-base.json" "$dir/snapshot.json" || exit 1
    [ "$traffic" = null ] || [ "$traffic" = "$(subscription_services_snapshot_section_traffic_context)" ] || exit 1
    mv "$tmpfile" "$dir/snapshot.json"
)

subscription_services_snapshot_continuity_section() {
    local section="$1" required
    validate_subscription_urltest_section "$section" || return 0
    required="$(subscription_required_services_json "$section")" || { SNAPSHOT_FAILED=1; return 0; }
    [ "$required" != '[]' ] || return 0
    jq -cn --arg section "$section" '$section' >> "$SNAPSHOT_SECTIONS" || SNAPSHOT_FAILED=1
}

subscription_services_snapshot_continuity_prepare() (
    # Continuity only: never read current node/evidence caches, bless new evidence,
    # regenerate a candidate, or apply desired settings to the saved runtime.
    local dir manifest config_path config_sha
    dir="$(subscription_services_snapshot_dir)"; manifest="$dir/snapshot.json"
    [ -s "$manifest" ] && [ ! -L "$dir" ] && [ ! -L "$manifest" ] || exit 1
    jq -e '.version==1 and (.sections|type=="array")
        and all(.sections[]; (.section|type=="string" and length>0)
            and (.admittedIds|type=="array" and length>0))
        and (.sections|map(.section)|length== (unique|length))' "$manifest" >/dev/null || exit 1
    config_get config_path settings config_path
    config_sha="$(subscription_services_snapshot_hash "$config_path")" || exit 1
    jq -e --arg config "$config_sha" '.config==$config' "$manifest" >/dev/null || exit 1
    SNAPSHOT_SECTIONS="$(mktemp)" || exit 1
    trap 'rm -f "$SNAPSHOT_SECTIONS"' EXIT INT TERM HUP
    SNAPSHOT_FAILED=0
    config_foreach subscription_services_snapshot_continuity_section section
    [ "$SNAPSHOT_FAILED" = 0 ] || exit 1
    # A disabled/removed or newly required section cannot silently reuse admission.
    jq -e --slurpfile current "$SNAPSHOT_SECTIONS" '(.sections|map(.section)|sort)==($current|sort)' "$manifest" >/dev/null || exit 1
    subscription_services_snapshot_restore_rules
)

subscription_services_snapshot_prepare() (
    local dir manifest config_path config_sha policy_sha generation path name hash actual
    dir="$(subscription_services_snapshot_dir)"; manifest="$dir/snapshot.json"
    [ -s "$manifest" ] && [ ! -L "$dir" ] && [ ! -L "$manifest" ] || exit 1
    jq -e '.version==1 and (.sections|type=="array" and length>0) and (.rules|type=="array")' "$manifest" >/dev/null || exit 1
    config_get config_path settings config_path
    config_sha="$(subscription_services_snapshot_hash "$config_path")" && policy_sha="$(subscription_services_snapshot_policy_hash)" || exit 1
    jq -e --arg config "$config_sha" --arg policy "$policy_sha" '.config==$config and .policy==$policy' "$manifest" >/dev/null || exit 1
    SNAPSHOT_SECTIONS="$(mktemp)" || exit 1
    trap 'rm -f "$SNAPSHOT_SECTIONS"' EXIT INT TERM HUP
    SNAPSHOT_FAILED=0; SNAPSHOT_CAPTURE=0; SNAPSHOT_BASE="$manifest"
    config_foreach subscription_services_snapshot_section section
    [ "$SNAPSHOT_FAILED" = 0 ] || exit 1
    jq -e --slurpfile current "$SNAPSHOT_SECTIONS" '(.sections|map(del(.admittedIds)))==($current|map(del(.admittedIds)))' "$manifest" >/dev/null || exit 1
    subscription_services_snapshot_restore_rules
)

subscription_services_snapshot_restore_rules() (
    local dir manifest config_path config_sha generation path name hash actual rules_file='' tmp_rule=''
    dir="$(subscription_services_snapshot_dir)"; manifest="$dir/snapshot.json"
    [ -s "$manifest" ] && [ ! -L "$dir" ] && [ ! -L "$manifest" ] || exit 1
    config_get config_path settings config_path
    config_sha="$(subscription_services_snapshot_hash "$config_path")" || exit 1
    jq -e --arg config "$config_sha" '.version==1 and .config==$config
        and (.rules|type=="array" and length<=128)
        and all(.rules[]; (.name|type=="string") and (.sha|type=="string" and length==64))
        and (.rules|map(.name)|length==(unique|length))' "$manifest" >/dev/null || exit 1
    # Bind the manifest to every exact local path in the frozen config, not merely
    # to a subset of copied files or names supplied by the manifest.
    jq -e --arg folder "$TMP_RULESET_FOLDER/" --slurpfile saved "$manifest" '
        [.route.rule_set[]? | select(.type=="local") | .path] | unique | sort
        == ($saved[0].rules | map($folder+.name) | sort)' "$config_path" >/dev/null || exit 1
    generation="$(jq -r '.generation' "$manifest")"
    case "$generation" in generation.*) case "${generation#generation.}" in ''|*[!A-Za-z0-9]*) exit 1;; esac;; *) exit 1;; esac
    [ -d "$dir/$generation" ] && [ ! -L "$dir/$generation" ] && [ ! -L "$TMP_RULESET_FOLDER" ] || exit 1
    rules_file="$(mktemp)" || exit 1
    trap 'rm -f "$rules_file"; [ -z "$tmp_rule" ] || rm -f "$tmp_rule"' EXIT INT TERM HUP
    jq -r '.rules[] | [.name,.sha] | @tsv' "$manifest" > "$rules_file" || exit 1
    # Validate every source and existing destination before restoring any missing file.
    while IFS="$(printf '\t')" read -r name hash; do
        case "$name" in ''|.|..|*[!A-Za-z0-9_.-]*) exit 1;; esac
        case "$name" in *.json|*.srs) ;; *) exit 1;; esac
        [ "${#hash}" = 64 ] || exit 1
        case "$hash" in *[!a-f0-9]*) exit 1;; esac
        actual="$(subscription_services_snapshot_hash "$dir/$generation/$name")" || exit 1
        [ "$actual" = "$hash" ] || exit 1
        path="$TMP_RULESET_FOLDER/$name"
        if [ -e "$path" ] || [ -L "$path" ]; then
            [ "$(subscription_services_snapshot_hash "$path")" = "$hash" ] || exit 1
        fi
    done < "$rules_file"
    mkdir -p "$TMP_RULESET_FOLDER" || exit 1
    while IFS="$(printf '\t')" read -r name hash; do
        path="$TMP_RULESET_FOLDER/$name"
        [ ! -f "$path" ] || continue
        tmp_rule="$(mktemp "$TMP_RULESET_FOLDER/.snapshot.XXXXXX")" || exit 1
        cp "$dir/$generation/$name" "$tmp_rule" && chmod 600 "$tmp_rule" || exit 1
        [ "$(subscription_services_snapshot_hash "$tmp_rule")" = "$hash" ] || exit 1
        mv "$tmp_rule" "$path" || exit 1
        tmp_rule=''
    done < "$rules_file"
    sing-box check -c "$config_path" >/dev/null 2>&1 || exit 1
)
# subscription_service_snapshot_v1 end
