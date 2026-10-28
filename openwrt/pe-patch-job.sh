#!/bin/sh
# Patch-only: no package operation, configuration change or proxy restart.
umask 077
pj_state() { printf '%s\n' "$1" > "$PT_JOB/state.next" && mv "$PT_JOB/state.next" "$PT_JOB/state"; }
pj_token() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
pj_alive() {
    case "$1:$2" in *[!0-9:]*|:*|*:) return 1;; esac
    kill -0 "$1" 2>/dev/null && [ "$(pj_token "$1")" = "$2" ]
}
pj_ui_reload() {
    pj_sync_config_trigger || return 1
    # Cache invalidation only; do not reload uhttpd or any network service.
    for cache in /tmp/luci-indexcache /tmp/luci-indexcache.*.json /tmp/luci-modulecache/*; do
        [ ! -f "$cache" ] || [ -L "$cache" ] || rm -f "$cache" || return 1
    done
    bounded 15 /etc/init.d/rpcd reload >/dev/null 2>&1
}
pj_sync_config_trigger() (
    # procd service.add without an instances member replaces triggers only.
    # Never call sing-box reload/start: that would re-submit the live instance.
    current=$(ubus call service list '{"name":"sing-box","verbose":true}') || exit 1
    enabled=false
    if grep -Fq 'procd_add_config_trigger "config.change" "podkop"' "$PT_ROOT/etc/init.d/sing-box"; then enabled=true; fi
    request=$(printf '%s' "$current" | jq -ce --argjson enabled "$enabled" '
        .["sing-box"] | select((.instances|type)=="object" and (.instances|length)>0) |
        ["config.change",["if",["eq","package","podkop"],["run_script","/etc/init.d/podkop","restart","on_config_change"]]] as $trigger |
        {name:"sing-box",triggers:((.triggers//[]|map(select(.[0:2]!=$trigger))) + (if $enabled then [$trigger] else [] end))}') || exit 1
    ubus call service add "$request" >/dev/null || exit 1
    expected=$(printf '%s' "$request" | jq -cS '.triggers') || exit 1
    actual=$(ubus call service list '{"name":"sing-box","verbose":true}') || exit 1
    actual=$(printf '%s' "$actual" | jq -cS '.["sing-box"].triggers//[]') || exit 1
    [ "$expected" = "$actual" ]
)
pj_fingerprint() (
    # Hashes only: no configuration contents or client identity leave the device.
    for path in /etc/config /etc/sing-box; do
        [ -d "$path" ] && [ ! -L "$path" ] || exit 1
        files=$(find "$path" -type f) || exit 1
        files=$(printf '%s\n' "$files" | LC_ALL=C sort) || exit 1
        while IFS= read -r file; do [ -z "$file" ] || sha256sum "$file" || exit 1; done <<EOF
$files
EOF
    done
    if [ -f /lib/apk/db/installed ]; then sha256sum /lib/apk/db/installed || exit 1
    elif [ -f /usr/lib/opkg/status ]; then sha256sum /usr/lib/opkg/status || exit 1
    else exit 1; fi
    sha256sum /usr/bin/sing-box || exit 1
)
pj_processes() (
    cat /proc/sys/kernel/random/boot_id || exit 1
    processes=$(for name in sing-box dnsmasq zerotier-one; do
        ids=$(pidof "$name" 2>/dev/null || true)
        [ "$name" = zerotier-one ] || [ -n "$ids" ] || exit 1
        for pid in $ids; do
            token=$(pj_token "$pid"); case "$token" in ''|*[!0-9]*) exit 1;; esac
            pj_alive "$pid" "$token" || exit 1
            printf '%s %s %s\n' "$name" "$pid" "$token"
        done
    done) || exit 1
    printf '%s\n' "$processes" | LC_ALL=C sort
)
pj_health() (
    changes=$(uci changes) && [ -z "$changes" ] || exit 1
    pj_fingerprint > "$PT_JOB/health.fingerprint" && cmp -s "$PT_JOB/health.fingerprint" "$PT_JOB/baseline.fingerprint" || exit 1
    pj_processes > "$PT_JOB/health.processes" && cmp -s "$PT_JOB/health.processes" "$PT_JOB/baseline.processes" || exit 1
    bounded 10 ubus call network.interface.wan status > "$PT_JOB/health.wan" && jq -e '.up==true' "$PT_JOB/health.wan" >/dev/null || exit 1
    bounded 10 nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1
)
pj_disarm() {
    hook="/etc/init.d/routerdesk-patch-${PT_JOB##*/}"
    link="/etc/rc.d/S08routerdesk-patch-${PT_JOB##*/}"
    [ ! -e "$link" ] || [ "$(readlink "$link")" = "../init.d/${hook##*/}" ] || return 1
    rm -f "$link" "$hook"
}
pj_unlock() {
    for lock in /tmp/podkop-subscription-action.lock.d /tmp/routerdesk-operation.lock; do
        [ "$(cat "$lock/routerdesk-job" 2>/dev/null)" = "$PT_JOB" ] || continue
        rm -f "$lock/owner" "$lock/routerdesk-job" || return 1
        rmdir "$lock" || return 1
    done
    if [ -s "$PT_JOB/action-owner" ] && [ "$(cat /tmp/podkop-subscription-action.lock 2>/dev/null)" = "$(cat "$PT_JOB/action-owner")" ]; then rm -f /tmp/podkop-subscription-action.lock; fi
}
pj_confirm() (
    mkdir "$PT_JOB/decision.lock" 2>/dev/null || exit 1
    trap 'rmdir "$PT_JOB/decision.lock"' EXIT
    [ "$(cat "$PT_JOB/state")" = awaiting-confirmation ] && pt_installed && pj_health || exit 1
    pj_state confirmed && sync && pj_finalize
)
pj_finalize() {
    pj_disarm && pj_unlock && : > "$PT_JOB/finalized" && sync
}
pj_rollback() (
    mkdir "$PT_JOB/decision.lock" 2>/dev/null || exit 1
    trap 'rmdir "$PT_JOB/decision.lock"' EXIT
    state=$(cat "$PT_JOB/state")
    case "$state:${1:-auto}" in confirmed:explicit|applying:*|awaiting-confirmation:*|rolling-back:*|recovery-required:*) ;;
        rolled-back:*) exit 0;; *) exit 1;; esac
    if [ "$state" = confirmed ]; then pt_installed && pj_lock || exit 1; fi
    rm -f "$PT_JOB/finalized" && pj_state rolling-back || exit 1
    if ! pt_restore || ! pj_ui_reload; then pj_state recovery-required; exit 1; fi
    # File restoration never regenerates config or starts the proxy.
    pj_state rolled-back && sync && pj_finalize
)
pj_arm() {
    hook="/etc/init.d/routerdesk-patch-${PT_JOB##*/}"
    link="/etc/rc.d/S08routerdesk-patch-${PT_JOB##*/}"
    [ ! -e "$hook" ] && [ ! -L "$hook" ] && [ ! -e "$link" ] && [ ! -L "$link" ] || return 1
    printf '#!/bin/sh /etc/rc.common\nSTART=08\nstart() { cd %s && sh ./job.sh boot; }\n' "$PT_JOB" > "$hook" && chmod 700 "$hook" && ln -s "../init.d/${hook##*/}" "$link" && sync
}
pj_lock() {
    [ ! -e /tmp/podkop-subscription-action.lock ] && [ ! -L /tmp/podkop-subscription-action.lock ] || return 1
    mkdir /tmp/routerdesk-operation.lock || return 1
    printf '%s\n' "$PT_JOB" > /tmp/routerdesk-operation.lock/routerdesk-job || return 1
    if ! mkdir /tmp/podkop-subscription-action.lock.d; then pj_unlock; return 1; fi
    printf '%s\n' "$PT_JOB" > /tmp/podkop-subscription-action.lock.d/routerdesk-job || return 1
    printf '%s migration %s\n' "$$" "$(date +%s)" > "$PT_JOB/action-owner" || return 1
    cp "$PT_JOB/action-owner" /tmp/podkop-subscription-action.lock.d/owner || return 1
    (set -C; cat "$PT_JOB/action-owner" > /tmp/podkop-subscription-action.lock)
}
pj_stage_init_integration() (
    helper=$(awk '$3=="usr/bin/podkop-sources-upgrade" {print $4}' "$PT_JOB/targets") || exit 1
    [ -n "$helper" ] || exit 0 # Older, hash-pinned releases retain their contract.
    pt_validate || exit 1
    runtime=$(awk '$3=="usr/bin/podkop" {print $4}' "$PT_JOB/targets") || exit 1
    [ -n "$runtime" ] && mkdir "$PT_JOB/init" || exit 1
    for name in podkop sing-box; do
        source="$PT_ROOT/etc/init.d/$name"
        pt_parent "etc/init.d/$name" && [ -f "$source" ] && [ ! -L "$source" ] || exit 1
        cp -p "$source" "$PT_JOB/init/$name" || exit 1
        sha256sum "$source" >> "$PT_JOB/init.before.sha256" || exit 1
    done
    before=$(sha256sum "$PT_JOB/new/$runtime") || exit 1
    PODKOP_SOURCES_TARGET="$PT_JOB/new/$runtime" PODKOP_SOURCES_SOURCE="$PT_JOB/new/$runtime" \
        PODKOP_SOURCES_INIT_TARGET="$PT_JOB/init/podkop" \
        PODKOP_SOURCES_ENGINE_INIT_TARGET="$PT_JOB/init/sing-box" \
        PODKOP_SOURCES_SAFE_RESTART_ONLY=1 sh "$PT_JOB/new/$helper" >/dev/null || exit 1
    [ "$before" = "$(sha256sum "$PT_JOB/new/$runtime")" ] || exit 1
    for name in podkop sing-box; do
        sh -n "$PT_JOB/init/$name" || exit 1
        index=$(wc -l < "$PT_JOB/targets")
        mv "$PT_JOB/init/$name" "$PT_JOB/new/$index" || exit 1
        printf '%s 755 etc/init.d/%s %s\n' "$(sha256sum "$PT_JOB/new/$index"|cut -d' ' -f1)" "$name" "$index" >> "$PT_JOB/targets" || exit 1
    done
    sha256sum -c "$PT_JOB/init.before.sha256" >/dev/null
)
pj_prepare() (
    [ ! -e "$PT_JOB/state" ] && [ ! -e "$PT_JOB/old" ] || exit 1
    case "$1" in podkop_patch_*) ;; *) exit 1;; esac
    case "$1" in *[!A-Za-z0-9_]*) exit 1;; esac
    for command in jq uci ubus sha256sum setsid tar gzip cmp; do command -v "$command" >/dev/null || exit 1; done
    # Existing init integration must already provide the safe restart contract.
    grep -Fqx '# subscription_safe_init_restart_v1' /etc/init.d/podkop &&
        sed -n '/^restart() {$/,/^}$/p' /etc/init.d/podkop | grep -Fq '/usr/bin/podkop restart' || exit 1
    pj_stage_init_integration || exit 1
    # memdoc modification is deliberately not part of a file-only update.
    [ ! -e /usr/bin/memdoc ] || { grep -Fq '# podkop_memdoc_guard begin' /usr/bin/memdoc && cmp -s /usr/bin/memdoc /usr/bin/memdoc.podkop-guarded; } || exit 1
    [ -f /usr/lib/uhttpd_ubus.so ] && [ "$(uci -q get uhttpd.main.ubus_prefix)" = /ubus ] || exit 1
    [ ! -e /tmp/podkop-subscription-action.lock ] && [ ! -e /tmp/podkop-subscription-action.lock.d ] && [ ! -e /tmp/routerdesk-operation.lock ] || exit 1
    changes=$(uci changes) && [ -z "$changes" ] || exit 1
    memory=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ "$memory" -ge 32768 ] || exit 1
    for type in acl menu; do
        if [ "$type" = acl ]; then
            path=usr/share/rpcd/acl.d/luci-app-podkop.json
            jq '.["luci-app-podkop"].read.file["/usr/bin/podkop-dns-benchmark"]=["exec"] | .["luci-app-podkop"].write.file["/usr/bin/podkop-dns-benchmark"]=["exec"] | .["luci-app-podkop"].read.file["/usr/bin/podkop-dns-optimizer"]=["exec"] | .["luci-app-podkop"].read.file["/usr/bin/podkop-update-manager"]=["exec"]' "/$path" > "$PT_JOB/acl.next" || exit 1
        else
            path=usr/share/luci/menu.d/luci-app-podkop.json
            jq --arg path "$1/podkop" '.["admin/services/podkop"].action={type:"view",path:$path}' "/$path" > "$PT_JOB/menu.next" || exit 1
        fi
        index=$(wc -l < "$PT_JOB/targets")
        mv "$PT_JOB/$type.next" "$PT_JOB/new/$index" || exit 1
        printf '%s 644 %s %s\n' "$(sha256sum "$PT_JOB/new/$index"|cut -d' ' -f1)" "$path" "$index" >> "$PT_JOB/targets"
    done
    pt_validate || exit 1
    while read -r _hash _mode path index; do
        case "$path" in *.sh|usr/bin/podkop|usr/bin/podkop-*|etc/init.d/*|usr/libexec/*) sh -n "$PT_JOB/new/$index" || exit 1;;
            *.json) jq -e 'type=="object"' "$PT_JOB/new/$index" >/dev/null || exit 1;; esac
    done < "$PT_JOB/targets"
    pj_fingerprint > "$PT_JOB/baseline.fingerprint" && pj_processes > "$PT_JOB/baseline.processes" && pj_health || exit 1
    pt_capture || exit 1
    [ ! -f "$PT_JOB/init.before.sha256" ] || sha256sum -c "$PT_JOB/init.before.sha256" >/dev/null || exit 1
    pj_state prepared
)
pj_worker() {
    printf '%s %s\n' "$$" "$(pj_token "$$")" > "$PT_JOB/worker.pid" || return 1
    mkdir "$PT_JOB/writer.lock" || return 1
    pj_state applying || return 1
    rc=0
    pt_install && pj_ui_reload && pj_health || rc=$?
    rmdir "$PT_JOB/writer.lock" || return 1
    if [ "$rc" = 0 ]; then pj_state awaiting-confirmation; else pj_rollback; fi
}
pj_watch() {
    pj_lock && pj_arm || { pj_state failed; pj_unlock; return 1; }
    printf '%s %s\n' "$$" "$(pj_token "$$")" > "$PT_JOB/watch.pid" || return 1
    setsid sh "$PT_JOB/job.sh" worker >> "$PT_JOB/job.log" 2>&1 < /dev/null &
    elapsed=0
    while [ "$elapsed" -lt 180 ]; do
        state=$(cat "$PT_JOB/state")
        case "$state" in confirmed|rolled-back) pj_finalize; return;; failed|recovery-required) return;; esac
        sleep 2; elapsed=$((elapsed+2))
    done
    if [ "$(cat "$PT_JOB/state")" = prepared ]; then pj_state failed; pj_disarm; pj_unlock; return 1; fi
    # Kill only the verified session leader and its private process group.
    if [ -f "$PT_JOB/worker.pid" ]; then
        read -r pid token < "$PT_JOB/worker.pid"
        if pj_alive "$pid" "$token"; then
            group=$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $3}')
            [ "$group" = "$pid" ] || { pj_state recovery-required; return 1; }
            kill -TERM -"$pid" 2>/dev/null || true
            sleep 2
            pj_alive "$pid" "$token" && kill -KILL -"$pid" 2>/dev/null || true
            sleep 1
            pj_alive "$pid" "$token" && { pj_state recovery-required; return 1; }
            for process in /proc/[0-9]*/stat; do
                [ -r "$process" ] || continue
                group=$(sed 's/^.*) //' "$process" 2>/dev/null | awk '{print $3}')
                [ "$group" != "$pid" ] || { pj_state recovery-required; return 1; }
            done
        elif [ -d "$PT_JOB/writer.lock" ]; then
            # An orphaned child may still own the filesystem write. Do not race it.
            pj_state recovery-required; return 1
        fi
    fi
    rmdir "$PT_JOB/writer.lock" 2>/dev/null || true
    pj_rollback
}
pj_main() {
    PT_ROOT=''; PT_JOB=$(pwd -P)
    case "$PT_JOB" in /root/routerdesk/*) ;; *) return 1;; esac
    id=${PT_JOB##*/}; case "$id" in *[!a-f0-9]*) return 1;; esac
    [ "${#id}" = 32 ] && [ ! -L "$PT_JOB" ] || return 1
    [ -f code.sha256 ] && [ ! -L code.sha256 ] || return 1
    awk 'NF!=2 || length($1)!=64 || $1~/[^a-f0-9]/ || $2!~/^(job|files|timeout)\.sh$/ {bad=1} {if(seen[$2]++)bad=1} END{exit(bad || NR!=3)}' code.sha256 && sha256sum -c code.sha256 >/dev/null || return 1
    . "$PT_JOB/files.sh"
    . "$PT_JOB/timeout.sh"
    case "$1" in
        prepare) pj_prepare "$2";;
        receipt) pt_receipt "$2";;
        start) [ "$(cat state)" = prepared ] && pt_verify_backup && pj_health && pt_baseline && [ -s pc-receipt ] || return 1
            [ ! -e dispatch ] && (set -C; : > dispatch) || return 1
            setsid sh "$PT_JOB/job.sh" watch >> job.log 2>&1 < /dev/null &
            printf 'STARTED\n';;
        watch) pj_watch;;
        worker) pj_worker;;
        confirm) pj_confirm;;
        rollback) [ ! -e "$PT_JOB/writer.lock" ] && pj_rollback explicit;;
        boot) case "$(cat state)" in confirmed|rolled-back) pj_finalize;; *) rmdir "$PT_JOB/writer.lock" "$PT_JOB/decision.lock" 2>/dev/null || true
                pj_state rolling-back
                if pt_restore; then pj_state rolled-back && pj_finalize; else pj_state recovery-required; fi;; esac;;
        status) state=$(cat state)
            case "$state" in confirmed|rolled-back) pj_finalize || state="$state-cleanup-pending";; esac
            printf 'PATCH=%s\n' "$state";;
        *) return 1;;
    esac
}
if [ "${1:-}" != --library ]; then pj_main "$@"; fi
