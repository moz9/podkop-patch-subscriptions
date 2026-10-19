#!/bin/sh
# Private HOME-only coordinator. No generic/public migration support and no i.
# An inspected, SHA-pinned offline adapter must implement preflight,
# install-deferred and verify-installed; it must enumerate ALL package/fork writes
# in plan.writePaths and never activate services or change user settings/graphs.
set -eu
umask 077
HM_SELF="$(readlink -f "$0")"

hm_error() { printf 'HOME migration refused: %s\n' "$*" >&2; return 1; }
hm_path() { printf '%s\n' "$1"; }
hm_hostname() { cat /proc/sys/kernel/hostname; }
hm_boot_id() { cat /proc/sys/kernel/random/boot_id; }
hm_sha() { sha256sum "$1" | awk '{print $1}'; }
hm_regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }

hm_validate_plan() {
    hm_regular "$1" || { hm_error plan_not_private_regular_file; return 1; }
    jq -e '
      def path: type=="string" and startswith("/") and length>1 and length<512
        and all(explode[]; (.>=48 and .<=57) or (.>=65 and .<=90) or (.>=97 and .<=122) or .==47 or .==46 or .==95 or .==45)
        and (split("/")|all(.[]; .!=".." and .!=".")) and (contains("//")|not);
      def hash: type=="string" and length==64 and all(explode[]; (.>=48 and .<=57) or (.>=97 and .<=102));
      . as $plan | .version==1 and .scope=="HOME-only" and .hostname=="WBR3000UAX"
      and (.bootId|type=="string" and length==36)
      and .target=={podkop:"0.7.24-r1",engine:"1.14.2-r14"}
      and (.guardFiles|type=="array" and length>0 and all(.[];(.path|path) and (.sha256|hash)))
      and ([.guardFiles[].path]|unique|length)==(.guardFiles|length)
      and (.graphPaths|type=="array" and length>=5 and all(.[];path))
      and (.graphPaths|unique|length)==(.graphPaths|length)
      and all(["/etc/sing-box/config.json","/etc/podkop/section-runtime/logical.json","/etc/podkop/section-runtime/frontend.json","/etc/podkop/section-runtime/workers/main/worker.json","/etc/podkop/section-runtime/workers/GEOBLOCK/worker.json"][]; . as $p|$plan.graphPaths|index($p)!=null)
      and (.writePaths|type=="array" and length>0 and all(.[];path)) and .writeSetComplete==true
      and all(["/usr/bin/sing-box","/usr/bin/podkop","/usr/bin/podkop-section-runtime","/usr/lib/podkop/section-hooks.sh","/etc/init.d/podkop","/etc/init.d/sing-box","/etc/init.d/podkop-section-worker","/lib/apk/db/installed","/lib/apk/db/scripts.tar.gz","/lib/apk/db/triggers","/lib/apk/db/lock"][]; . as $p|$plan.writePaths|index($p)!=null)
      and .externalDevice=="/dev/sda1"
      and (if .binaryRelease.enabled // false then
        .binaryRelease.path=="/usr/bin/sing-box" and (.binaryRelease.oldSha256|hash)
        and all(.binaryRelease|.oldSizeBytes,.finalAllocationKiB,.minFinalFreeKiB; type=="number" and .>0 and floor==.) else true end)
      and (.assets|type=="array" and length>0 and all(.[];(.path|path) and (.sha256|hash)))
      and (.installAdapter.path|path) and (.installAdapter.sha256|hash)
      and (.installAdapter as $a|any(.assets[];.path==$a.path and .sha256==$a.sha256))
      and (if .statCommand then (.statCommand.path|path) and (.statCommand.sha256|hash) and (.statCommand as $a|any(.assets[];.path==$a.path and .sha256==$a.sha256)) else true end)
      and (.constraints|type=="array" and length>=2 and all(.[]; (.path|path) and (.minFreeKiB|type=="number" and .>0 and floor==.) and
        (if .inodePolicy=="ubifs_dynamic" then .path=="/overlay" and .minFreeInodes==0 else (.inodePolicy // "finite")=="finite" and (.minFreeInodes|type=="number" and .>0 and floor==.) end)))
      and any(.constraints[];.path=="/overlay") and any(.constraints[];.path=="/mnt/storage")
    ' "$1" >/dev/null || { hm_error invalid_or_incomplete_home_plan; return 1; }
    # Every graph/config is pinned, not simply named by the operator.
    jq -e '. as $p|all(.graphPaths[]; . as $g|any($p.guardFiles[];.path==$g)) and any(.guardFiles[];.path=="/etc/config/podkop")' "$1" >/dev/null || { hm_error unpinned_graph; return 1; }
}

hm_identity_guard() {
    [ "$(hm_hostname)" = "$(jq -r '.hostname' "$1")" ] || { hm_error wrong_home_hostname; return 1; }
    [ "$(hm_boot_id)" = "$(jq -r '.bootId' "$1")" ] || { hm_error boot_changed; return 1; }
}

hm_mount_table() { cat /proc/mounts; }
hm_storage_guard() {
    [ "$(hm_mount_table | awk '$2=="/mnt/storage" && $3=="ext4" && $4 ~ /^rw[, ]/ {print $1}')" = "$(jq -r '.externalDevice' "$1")" ] || { hm_error external_disk_identity_changed; return 1; }
}

hm_resource_free() {
    # Both tables must be available; filesystem pressure never becomes zero.
    local kib inodes plan="${2:-}" stat_command stats fs_type total free
    kib="$(df -Pk "$(hm_path "$1")" | awk 'NR==2 {print $4}')" || return 1
    case "$kib" in ''|*[!0-9]*) return 1;; esac
    inodes="$(df -Pi "$(hm_path "$1")" 2>/dev/null | awk 'NR==2 {print $4}')"
    case "$inodes" in ''|*[!0-9]*)
        [ -n "$plan" ] || return 1
        stat_command="$(jq -er '.statCommand.path' "$plan")" || return 1
        stats="$("$(hm_path "$stat_command")" --file-system --format='%T %c %d' "$(hm_path "$1")")" || return 1
        fs_type="${stats%% *}"; stats="${stats#* }"; total="${stats%% *}"; free="${stats#* }"
        case "$total:$free" in *[!0-9:]*|:*) return 1;; esac
        if [ "$fs_type" = ubifs ] && [ "$total" = 0 ] && [ "$free" = 0 ]; then
            printf '%s dynamic_ubifs\n' "$kib"; return 0
        fi
        inodes="$free"
        ;;
    esac
    case "$kib:$inodes" in *[!0-9:]*|:*) return 1;; esac
    printf '%s %s\n' "$kib" "$inodes"
}

hm_release_admitted() {
    local plan="$1" available="$2" old hash bytes allocation reserve
    [ "$(jq -r '.binaryRelease.enabled // false' "$plan")" = true ] || return 1
    old="$(hm_path /usr/bin/sing-box)"
    hm_regular "$old" || return 1
    hash="$(jq -r '.binaryRelease.oldSha256' "$plan")"
    bytes="$(jq -r '.binaryRelease.oldSizeBytes' "$plan")"
    [ "$(hm_sha "$old")" = "$hash" ] && [ "$(wc -c < "$old")" = "$bytes" ] || return 1
    allocation="$(jq -r '.binaryRelease.finalAllocationKiB' "$plan")"
    reserve="$(jq -r '.binaryRelease.minFinalFreeKiB' "$plan")"
    [ "$((available + (bytes+1023)/1024 - allocation))" -ge "$reserve" ]
}

hm_check_assets() {
    local plan="$1" asset digest file rows
    rows="$(jq -r '.assets[]|[.path,.sha256]|@tsv' "$plan")" || return 1
    while IFS="$(printf '\t')" read -r asset digest; do
        file="$(hm_path "$asset")"
        hm_regular "$file" && [ "$(hm_sha "$file")" = "$digest" ] || { hm_error asset_hash_changed; return 1; }
    done <<EOF
$rows
EOF
}

hm_check_guards() {
    local rows path hash file
    rows="$(jq -r '.guardFiles[]|[.path,.sha256]|@tsv' "$1")" || return 1
    while IFS="$(printf '\t')" read -r path hash; do
        file="$(hm_path "$path")"
        hm_regular "$file" && [ "$(hm_sha "$file")" = "$hash" ] || { hm_error "guard_changed:$path"; return 1; }
    done <<EOF
$rows
EOF
}

hm_check_graph_guards() {
    local plan="$1" rows path hash file
    rows="$(jq -r '. as $p|.guardFiles[]|select((.path|startswith("/etc/config/")) or (.path as $g|$p.graphPaths|index($g)!=null))|[.path,.sha256]|@tsv' "$plan")" || return 1
    while IFS="$(printf '\t')" read -r path hash; do
        file="$(hm_path "$path")"
        hm_regular "$file" && [ "$(hm_sha "$file")" = "$hash" ] || { hm_error "frozen_graph_changed:$path"; return 1; }
    done <<EOF
$rows
EOF
}

hm_service_guard() (
    # Capture only these two owned services. Every actual sing-box PID must be
    # registered to one expected frozen config; unknown processes fail closed.
    plan="$1"; records="$(mktemp)"; known="$(mktemp)"
    trap 'rm -f "$records" "$known"' EXIT INT TERM HUP
    for service in sing-box podkop-section-worker; do
        ubus call service list "{\"name\":\"$service\"}" | jq -er --arg s "$service" '
          (.[$s].instances // {})|to_entries[]?|select(.value.running==true)
          | .value as $v|($v.command|index("-c")) as $i
          | select(($v.pid|type=="number" and .>1 and floor==.) and $i!=null)
          | [$v.pid,$v.command[0],$v.command[$i+1]]|@tsv' >> "$records" || return 1
    done
    while IFS="$(printf '\t')" read -r pid bin cfg; do
        [ "$bin" = /usr/bin/sing-box ] || return 1
        jq -e --arg c "$cfg" '.graphPaths|index($c)!=null' "$plan" >/dev/null || return 1
        [ -r "/proc/$pid/cmdline" ] && [ "$(readlink "/proc/$pid/exe")" = "$bin" ] || return 1
        tr '\000' '\n' < "/proc/$pid/cmdline" | awk -v b="$bin" -v c="$cfg" 'NR==1&&$0!=b{bad=1}prev=="-c"&&$0==c{found=1}{prev=$0}END{exit(bad||!found)}' || return 1
        printf '%s\n' "$pid" >> "$known"
    done < "$records"
    for pid in $(pidof sing-box 2>/dev/null || true); do grep -Fxq "$pid" "$known" || return 1; done
    LC_ALL=C sort "$records"
)

hm_guard() {
    local plan="$1" rows path min_kib min_inode policy free available_kib available_inode
    hm_validate_plan "$plan" && hm_identity_guard "$plan" && hm_storage_guard "$plan" && hm_check_guards "$plan" && hm_check_assets "$plan" || return 1
    rows="$(jq -r '.constraints[]|[.path,.minFreeKiB,.minFreeInodes,(.inodePolicy // "finite")]|@tsv' "$plan")" || return 1
    while IFS="$(printf '\t')" read -r path min_kib min_inode policy; do
        free="$(hm_resource_free "$path" "$plan")" || { hm_error resource_inventory_unavailable; return 1; }
        available_kib="${free%% *}"; available_inode="${free#* }"
        if [ "$available_inode" = dynamic_ubifs ]; then
            [ "$path:$policy" = /overlay:ubifs_dynamic ] || { hm_error explicit_dynamic_inode_policy_required; return 1; }
        else
            [ "$policy" = finite ] && [ "$available_inode" -ge "$min_inode" ] || { hm_error "inode_floor:$path"; return 1; }
        fi
        if [ "$available_kib" -lt "$min_kib" ]; then
            [ "$path" = /overlay ] && hm_release_admitted "$plan" "$available_kib" || { hm_error "space_floor:$path"; return 1; }
        fi
    done <<EOF
$rows
EOF
    hm_service_guard "$plan" >/dev/null || { hm_error unknown_service_graph; return 1; }
}

hm_adapter() {
    local action="$1" plan="$2" transaction="$3" adapter
    hm_check_assets "$plan" || return 1
    adapter="$(jq -r '.installAdapter.path' "$plan")"
    sh "$(hm_path "$adapter")" "$action" "$plan" "$transaction"
}

hm_collect_paths() {
    local plan="$1" destination="$2" configs cfg references
    jq -r '[.writePaths[],.guardFiles[].path,.graphPaths[]]|unique|.[]' "$plan" > "$destination" || return 1
    configs="$(jq -r '.graphPaths[]' "$plan")" || return 1
    while IFS= read -r cfg; do
        # Both sing-box DNS and route local rule datasets are frozen, not fetched
        # or regenerated. Recursive lookup catches logical rules beneath groups.
        references="$(jq -r '[..|objects|select(.type?=="local")|.path? // empty]|unique|.[]' "$(hm_path "$cfg")")" || return 1
        [ -z "$references" ] || printf '%s\n' "$references" >> "$destination"
    done <<EOF
$configs
EOF
    LC_ALL=C sort -u "$destination" > "$destination.sorted" && mv "$destination.sorted" "$destination"
}

hm_allowed_restore_path() {
    local anchor
    case "$1" in
        /usr/bin/*|/usr/lib/podkop/*|/usr/libexec/podkop-engine/*|/usr/share/podkop/*|/usr/share/sing-box/*|/lib/apk/*|/lib/upgrade/keep.d/podkop-engine|/etc/apk/*|/etc/init.d/sing-box|/etc/init.d/podkop|/etc/init.d/podkop-section-worker|/etc/init.d/podkop-engine|/etc/init.d/podkop-dns-failover|/etc/config/podkop|/etc/config/sing-box|/etc/config/dhcp|/etc/config/network|/etc/config/firewall|/etc/config/uhttpd|/etc/uci-defaults/50_luci-podkop|/etc/uci-defaults/99-podkop-engine|/etc/sing-box/*|/etc/podkop/*|/tmp/sing-box/rulesets/*|/www/luci-static/resources/*|/usr/share/rpcd/acl.d/*|/usr/share/luci/menu.d/*|/usr/lib/lua/luci/*) ;;
        *) return 1;;
    esac
    case "$1" in *'/../'*|*'/./'*|*'//'*|*/..|*/.|*[!A-Za-z0-9_./-]*) return 1;; esac
    anchor="$(hm_path "$(dirname "$1")")"
    while [ ! -e "$anchor" ] && [ ! -L "$anchor" ]; do anchor="$(dirname "$anchor")"; done
    [ ! -L "$anchor" ] && [ "$(readlink -f "$anchor")" = "$anchor" ]
}

hm_state() {
    local tx="$1" phase="$2" sha archive inventory boot paths absent services
    sha="$(hm_sha "$tx/plan.json")"; archive="$(hm_sha "$tx/rollback.tar")"; inventory="$(hm_sha "$tx/rollback.sha256")"
    boot="$(jq -r '.bootId' "$tx/plan.json")"
    paths="$(hm_sha "$tx/paths")"; absent="$(hm_sha "$tx/absent")"; services="$(hm_sha "$tx/services.before")"
    jq -cn --arg phase "$phase" --arg plan "$sha" --arg archive "$archive" --arg inventory "$inventory" --arg boot "$boot" --arg paths "$paths" --arg absent "$absent" --arg services "$services" '{version:1,scope:"HOME-only",phase:$phase,planSha256:$plan,archiveSha256:$archive,inventorySha256:$inventory,pathsSha256:$paths,absentSha256:$absent,servicesSha256:$services,bootId:$boot}' > "$tx/state.json.next" && mv "$tx/state.json.next" "$tx/state.json"
}

hm_prepare() (
    plan="$1"
    hm_guard "$plan" || exit 1
    parent="$(hm_path /mnt/storage/podkop-pe-migration)"
    [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(readlink -f "$parent")" = "$parent" ] || exit 1
    tx="$(mktemp -d "$parent/home-0724.XXXXXX")" || exit 1
    cp -p "$plan" "$tx/plan.json" || exit 1
    hm_adapter preflight "$tx/plan.json" "$tx" || exit 1
    hm_service_guard "$plan" > "$tx/services.before" || exit 1
    mkdir "$tx/rollback" || exit 1
    hm_collect_paths "$plan" "$tx/paths" || { hm_error local_rules_inventory_failed; exit 1; }
    : > "$tx/absent"
    while IFS= read -r path; do
        hm_allowed_restore_path "$path" || { hm_error "unapproved_restore_path:$path"; exit 1; }
        source="$(hm_path "$path")"; destination="$tx/rollback$path"
        if [ -e "$source" ] || [ -L "$source" ]; then
            hm_regular "$source" || { hm_error "snapshot_not_regular:$path"; exit 1; }
            mkdir -p "$(dirname "$destination")" && cp -p "$source" "$destination" || exit 1
            [ "$(hm_sha "$source")" = "$(hm_sha "$destination")" ] || exit 1
        else
            # Only inspector-confirmed new package/fork files may be absent.
            jq -e --arg p "$path" '.writePaths|index($p)!=null' "$plan" >/dev/null || { hm_error "missing_frozen_rule_or_graph:$path"; exit 1; }
            printf '%s\n' "$path" >> "$tx/absent"
        fi
    done < "$tx/paths"
    (cd "$tx/rollback" && find . -type f -exec sha256sum '{}' ';' | LC_ALL=C sort) > "$tx/rollback.sha256" || exit 1
    (cd "$tx/rollback" && sha256sum -c "$tx/rollback.sha256" >/dev/null) || exit 1
    tar -C "$tx/rollback" -cf "$tx/rollback.tar" . || exit 1
    tar -tf "$tx/rollback.tar" >/dev/null || exit 1
    hm_guard "$plan" || exit 1
    hm_state "$tx" prepared || exit 1
    printf '%s\n' "$tx"
)

hm_verify_snapshot() {
    local tx="$1"
    [ "$(dirname "$tx")" = "$(hm_path /mnt/storage/podkop-pe-migration)" ] && [ ! -L "$tx" ] || return 1
    case "$(basename "$tx")" in home-0724.*) ;; *) return 1;; esac
    hm_regular "$tx/plan.json" && hm_regular "$tx/state.json" && hm_regular "$tx/rollback.tar" && hm_regular "$tx/rollback.sha256" || return 1
    hm_validate_plan "$tx/plan.json" && hm_identity_guard "$tx/plan.json" || return 1
    jq -e --arg p "$(hm_sha "$tx/plan.json")" --arg a "$(hm_sha "$tx/rollback.tar")" --arg i "$(hm_sha "$tx/rollback.sha256")" --arg paths "$(hm_sha "$tx/paths")" --arg absent "$(hm_sha "$tx/absent")" --arg services "$(hm_sha "$tx/services.before")" '.scope=="HOME-only" and .planSha256==$p and .archiveSha256==$a and .inventorySha256==$i and .pathsSha256==$paths and .absentSha256==$absent and .servicesSha256==$services' "$tx/state.json" >/dev/null || { hm_error snapshot_hash_changed; return 1; }
    (cd "$tx/rollback" && sha256sum -c "$tx/rollback.sha256" >/dev/null) || { hm_error rollback_files_changed; return 1; }
}

hm_stop_owned() { /etc/init.d/sing-box stop 9>&- && /etc/init.d/podkop-section-worker stop 9>&-; }
hm_start_owned() { /etc/init.d/podkop-section-worker start 9>&- && /etc/init.d/sing-box start 9>&-; }
hm_prove_stopped() {
    local attempts=0 service good
    while [ "$attempts" -lt 8 ]; do
        good=1
        for service in sing-box podkop-section-worker; do
            ubus call service list "{\"name\":\"$service\"}" | jq -e --arg s "$service" '[.[$s].instances[]?|select(.running==true)]|length==0' >/dev/null || good=0
        done
        [ -z "$(pidof sing-box 2>/dev/null || true)" ] || good=0
        [ "$good" = 1 ] && return 0
        attempts=$((attempts+1)); sleep 1
    done
    hm_error service_owners_remain
}

hm_maybe_release_binary() {
    local tx="$1" plan="$1/plan.json" free available peak old sha
    [ "$(jq -r '.binaryRelease.enabled // false' "$plan")" = true ] || return 0
    free="$(hm_resource_free /overlay "$plan")" || return 1; available="${free%% *}"
    peak="$(jq -r '.constraints[]|select(.path=="/overlay")|.minFreeKiB' "$plan")"
    [ "$available" -lt "$peak" ] || return 0
    hm_release_admitted "$plan" "$available" && hm_prove_stopped || return 1
    old="$(hm_path /usr/bin/sing-box)"; sha="$(jq -r '.binaryRelease.oldSha256' "$plan")"
    hm_verify_snapshot "$tx" && hm_regular "$tx/rollback/usr/bin/sing-box" && [ "$(hm_sha "$tx/rollback/usr/bin/sing-box")" = "$sha" ] || return 1
    jq -e --arg a "$(hm_sha "$tx/rollback.tar")" '.verifiedLocalArchiveSha256==$a' "$tx/local-copy-receipt.json" >/dev/null || return 1
    # Single explicit regular file, never a glob/directory/symlink or process kill.
    rm -f "$old" || return 1
    [ ! -e "$old" ] || return 1
    hm_state "$tx" binary_released
}
hm_validate_configs() {
    local plan="$1" configs config
    configs="$(jq -r '.graphPaths[]|select(endswith("/metadata.json")|not)' "$plan")" || return 1
    while IFS= read -r config; do
        /usr/bin/sing-box check -c "$config" >/dev/null 2>&1 || { hm_error "new_engine_rejects_frozen_config:$config"; return 1; }
    done <<EOF
$configs
EOF
}
hm_wait_owned() {
    local attempts=0
    /usr/bin/podkop-section-runtime wait-ready >/dev/null || return 1
    while [ "$attempts" -lt 8 ]; do
        ubus call service list '{"name":"sing-box"}' | jq -e '[."sing-box".instances[]?|select(.running==true)]|length==1' >/dev/null && return 0
        attempts=$((attempts+1)); sleep 1
    done
    return 1
}

hm_restore_group() {
    local tx="$1" rules="$2" path source destination
    while IFS= read -r path; do
        case "$rules:$path" in yes:/tmp/sing-box/rulesets/*) ;; yes:*) continue;; no:/tmp/sing-box/rulesets/*) continue;; esac
        hm_allowed_restore_path "$path" || return 1
        source="$tx/rollback$path"; destination="$(hm_path "$path")"
        [ ! -L "$destination" ] || return 1
        if [ -f "$source" ]; then
            mkdir -p "$(dirname "$destination")" && cp -p "$source" "$destination" || return 1
            [ "$(hm_sha "$source")" = "$(hm_sha "$destination")" ] || return 1
        elif grep -Fxq "$path" "$tx/absent"; then
            [ ! -d "$destination" ] || return 1
            rm -f "$destination" || return 1
        else return 1; fi
    done < "$tx/paths"
}

hm_rollback_body() {
    local tx="$1"
    hm_verify_snapshot "$tx" || return 1
    hm_stop_owned && hm_prove_stopped || { hm_state "$tx" rollback_failed; return 1; }
    # Restore frozen ephemeral lists BEFORE old binary/init/hooks/DB and start.
    if hm_restore_group "$tx" yes && hm_restore_group "$tx" no && hm_start_owned && hm_wait_owned; then
        hm_state "$tx" rolled_back
    else
        hm_state "$tx" rollback_failed
        hm_error rollback_not_ready
    fi
}

hm_lock_transaction() {
    local tx="$1" start
    exec 9> "$tx/operation.lock"
    flock -n 9 || { hm_error transaction_writer_busy; return 1; }
    start="$(awk '{print $22}' "/proc/$$/stat")" || return 1
    printf '%s %s %s\n' "$$" "$start" "$(hm_boot_id)" > "$tx/operation.owner"
}

hm_rollback() (
    tx="$1"
    hm_verify_snapshot "$tx" && hm_lock_transaction "$tx" || exit 1
    hm_rollback_body "$tx"
)

hm_global_lock_acquire() {
    local dir file
    dir="$(hm_path /tmp/podkop-subscription-action.lock.d)"; file="$(hm_path /tmp/podkop-subscription-action.lock)"
    # Do not steal even a stale lock; the native, inspected recovery path owns it.
    [ ! -e "$file" ] && [ ! -L "$file" ] || return 1
    mkdir "$dir" 2>/dev/null || return 1
    printf '%s home_pe_0724 %s\n' "$$" "$(date +%s)" > "$dir/owner" || { rmdir "$dir" 2>/dev/null || true; return 1; }
    if ! (set -C; printf '%s home_pe_0724 %s\n' "$$" "$(date +%s)" > "$file") 2>/dev/null; then
        rm -f "$dir/owner"; rmdir "$dir" 2>/dev/null || true; return 1
    fi
}

hm_global_lock_release() {
    local dir file owner
    dir="$(hm_path /tmp/podkop-subscription-action.lock.d)"; file="$(hm_path /tmp/podkop-subscription-action.lock)"
    owner="$(awk 'NR==1{print $1}' "$dir/owner" 2>/dev/null || true)"
    if [ "$owner" = "$$" ]; then rm -f "$dir/owner"; rmdir "$dir" 2>/dev/null || true; fi
    owner="$(awk 'NR==1{print $1}' "$file" 2>/dev/null || true)"
    [ "$owner" != "$$" ] || rm -f "$file"
}

hm_watchdog_alive() {
    local tx="$1" pid start
    hm_regular "$tx/watchdog.ready.json" || return 1
    pid="$(jq -er '.pid|select(type=="number" and .>1 and floor==.)' "$tx/watchdog.ready.json")" || return 1
    [ -r "/proc/$pid/stat" ] && [ -r "/proc/$pid/cmdline" ] || return 1
    start="$(awk '{print $22}' "/proc/$pid/stat")" || return 1
    jq -e --arg s "$start" --arg b "$(hm_boot_id)" --arg t "$tx" --arg code "$(hm_sha "$HM_SELF")" '.starttime==$s and .bootId==$b and .transaction==$t and .coordinatorSha256==$code' "$tx/watchdog.ready.json" >/dev/null || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$tx" || return 1
    kill -0 "$pid" 2>/dev/null
}

hm_global_lock_guard() {
    local tx="$1" pid dir file
    hm_watchdog_alive "$tx" || return 1
    pid="$(jq -r '.pid' "$tx/watchdog.ready.json")"
    dir="$(hm_path /tmp/podkop-subscription-action.lock.d)"; file="$(hm_path /tmp/podkop-subscription-action.lock)"
    [ ! -L "$dir" ] && [ ! -L "$file" ] || return 1
    [ "$(awk 'NR==1{print $1}' "$dir/owner")" = "$pid" ] && [ "$(awk 'NR==1{print $1}' "$file")" = "$pid" ]
}

hm_start_watchdog() {
    local tx="$1" attempts=0
    if [ -e "$tx/watchdog.ready.json" ]; then hm_watchdog_alive "$tx" && hm_global_lock_guard "$tx"; return $?; fi
    command -v start-stop-daemon >/dev/null && command -v flock >/dev/null || return 1
    start-stop-daemon -S -b -m -p "$tx/watchdog.pid" -x /bin/sh -- "$HM_SELF" watch "$tx" 9>&- || return 1
    while [ "$attempts" -lt 5 ]; do
        hm_watchdog_alive "$tx" && hm_global_lock_guard "$tx" && return 0
        attempts=$((attempts+1)); sleep 1
    done
    hm_error independent_watchdog_not_ready
}

hm_watchdog_tick() {
    local tx="$1" deadline="$2" now="$3" phase
    phase="$(jq -r '.phase' "$tx/state.json")" || return 1
    case "$phase" in confirmed|rolled_back) HM_WATCH_DONE=1; return 0;; esac
    [ "$now" -ge "$deadline" ] || return 0
    if [ "$phase" = prepared ]; then HM_WATCH_DONE=1; return 0; fi
    printf 'deadline reached\n' > "$tx/watchdog.abort"
    if hm_rollback "$tx"; then HM_WATCH_DONE=1; return 0; fi
    printf 'rollback deferred: transaction locked or recovery guard failed\n' > "$tx/watchdog.recovery-required"
    return 1
}

hm_watch() {
    local tx="$1" deadline start failures=0
    hm_verify_snapshot "$tx" && hm_global_lock_acquire || return 1
    trap hm_global_lock_release EXIT
    trap 'exit 130' INT TERM HUP
    start="$(awk '{print $22}' "/proc/$$/stat")"; deadline=$(( $(date +%s) + 600 ))
    jq -cn --argjson p "$$" --arg s "$start" --arg b "$(hm_boot_id)" --arg t "$tx" --arg code "$(hm_sha "$HM_SELF")" --argjson deadline "$deadline" '{pid:$p,starttime:$s,bootId:$b,transaction:$t,coordinatorSha256:$code,deadline:$deadline}' > "$tx/watchdog.ready.json"
    HM_WATCH_DONE=0
    while [ "$HM_WATCH_DONE" = 0 ]; do
        if hm_watchdog_tick "$tx" "$deadline" "$(date +%s)"; then failures=0; else failures=$((failures+1)); fi
        # Never race a still-running APK/i child holding the inherited flock.
        [ "$failures" -lt 12 ] || return 1
        [ "$HM_WATCH_DONE" != 0 ] || sleep 5
    done
}

hm_arm() {
    hm_verify_snapshot "$1" || return 1
    [ "$(jq -r '.phase' "$1/state.json")" = prepared ] || return 1
    hm_start_watchdog "$1" && hm_global_lock_guard "$1"
}

hm_confirm() (
    tx="$1"
    hm_verify_snapshot "$tx" && hm_lock_transaction "$tx" || exit 1
    [ "$(jq -r '.phase' "$tx/state.json")" = activated ] && [ ! -f "$tx/watchdog.abort" ] || exit 1
    hm_global_lock_guard "$tx" && hm_check_assets "$tx/plan.json" && hm_check_graph_guards "$tx/plan.json" && hm_adapter verify-installed "$tx/plan.json" "$tx" && hm_wait_owned || exit 1
    hm_service_guard "$tx/plan.json" > "$tx/services.confirm" || exit 1
    pids="$(cut -f1 "$tx/services.confirm" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)|sort')" || exit 1
    hm_regular "$tx/external-verification.json" && jq -e --arg boot "$(hm_boot_id)" --argjson now "$(date +%s)" --argjson pids "$pids" '.version==1 and .bootId==$boot and .checkedAt>($now-300) and .checkedAt<=$now and .clientDns==true and .workerHttps==true and .stablePids==true and (.pids|sort)==$pids' "$tx/external-verification.json" >/dev/null || { hm_error external_verification_missing; exit 1; }
    hm_state "$tx" confirmed
)

hm_apply() (
    tx="$1"
    hm_verify_snapshot "$tx" || exit 1
    hm_lock_transaction "$tx" || exit 1
    [ "$(jq -r '.phase' "$tx/state.json")" = prepared ] || { hm_error transaction_not_prepared; exit 1; }
    hm_regular "$tx/local-copy-receipt.json" && jq -e --arg a "$(hm_sha "$tx/rollback.tar")" --arg boot "$(hm_boot_id)" '.version==1 and .verifiedLocalArchiveSha256==$a and .bootId==$boot' "$tx/local-copy-receipt.json" >/dev/null || { hm_error local_archive_not_verified; exit 1; }
    hm_guard "$tx/plan.json" || exit 1
    hm_service_guard "$tx/plan.json" > "$tx/services.now" || exit 1
    cmp -s "$tx/services.before" "$tx/services.now" || { hm_error active_graph_changed; exit 1; }
    hm_start_watchdog "$tx" && hm_global_lock_guard "$tx" || exit 1
    hm_state "$tx" installing || exit 1
    trap 'trap - INT TERM HUP; hm_rollback_body "$tx" || true; exit 130' INT TERM HUP
    if hm_stop_owned && hm_prove_stopped && hm_maybe_release_binary "$tx" && hm_adapter install-deferred "$tx/plan.json" "$tx" && [ ! -f "$tx/watchdog.abort" ] && hm_global_lock_guard "$tx" && hm_adapter verify-installed "$tx/plan.json" "$tx" && hm_check_graph_guards "$tx/plan.json" && hm_validate_configs "$tx/plan.json" && hm_start_owned && hm_wait_owned; then
        hm_state "$tx" activated || exit 1
        trap - INT TERM HUP
        exit 0
    fi
    hm_rollback_body "$tx" || { hm_error recovery_required; exit 1; }
    exit 1
)

[ "${HOME_PE_MIGRATION_LIBRARY_ONLY:-0}" != 1 ] || return 0
case "${1:-}" in
    prepare) [ "$#" = 2 ] || exit 2; hm_prepare "$2";;
    apply) [ "$#" = 2 ] || exit 2; hm_apply "$2";;
    rollback) [ "$#" = 2 ] || exit 2; hm_rollback "$2";;
    confirm) [ "$#" = 2 ] || exit 2; hm_confirm "$2";;
    arm) [ "$#" = 2 ] || exit 2; hm_arm "$2";;
    watch) [ "$#" = 2 ] || exit 2; hm_watch "$2";;
    *) printf 'Usage: %s prepare PLAN.json | apply TRANSACTION | rollback TRANSACTION | confirm TRANSACTION\n' "$0" >&2; exit 2;;
esac
