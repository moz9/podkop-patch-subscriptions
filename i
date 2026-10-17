#!/bin/sh
# Explicit TEST candidate, never the stable channel.
set -eu
export LC_ALL=C
candidate_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
candidate_platform() {
    [ "$1:$2:$3:$4" = '25.12.5:aarch64_cortex-a53:aarch64:redmi,ax6' ] ||
        candidate_fail 'requires Redmi AX6 / OpenWrt 25.12.5 / APK aarch64'
}
candidate_mode() {
    case "$1:$2:$3" in
        ::) printf 'fresh\n' ;;
        0.7.24-r1:0.7.24-r1:1.14.2-r14) printf 'existing\n' ;;
        *) candidate_fail 'partial/legacy/incompatible stack; migration refused' ;;
    esac
}
candidate_hash() {
    [ "${#1}" = 64 ] || candidate_fail 'invalid SHA pin'
    case "$1" in *[!a-f0-9]*) candidate_fail 'invalid SHA pin' ;; esac
    printf '%s  %s\n' "$1" "$2" | sha256sum -c - || candidate_fail 'SHA mismatch; nothing installed'
}
candidate_fetch() {
    case "$1" in https://*) ;; *) candidate_fail 'HTTPS required' ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --proto-redir '=https' -fSL --connect-timeout 10 --max-time 120 "$1" -o "$2"
    else wget -T 120 -O "$2" "$1"; fi
}
candidate_simulate() {
    plan=$1; shift
    apk -vv --simulate add "$@" > "$plan" 2>&1 || candidate_fail 'APK dependency/ABI simulation failed; no packages changed'
    if grep -Ei 'upgrad|downgrad|reinstall|replac|purg|remov|break|unsatisf|conflict|ERROR:' "$plan" >/dev/null; then
        candidate_fail 'APK plan alters existing packages or has conflicts'
    fi
}
candidate_plan_kib() {
    awk -v kind="$2" '
        function kib(n,u, scale,x) {
            if(n !~ /^[0-9]+([.][0-9]+)?$/) exit 1;
            if(u=="B") scale=1/1024; else if(u=="KiB") scale=1;
            else if(u=="MiB") scale=1024; else if(u=="GiB") scale=1048576; else exit 1;
            x=(n+1)*scale; return int(x)+(x>int(x));
        }
        kind=="growth" && /^After this operation, / && / of additional disk space will be used[.]$/ {n++; value=kib($4,$5)}
        kind=="download" && /^Need to download / && / of packages[.]$/ {n++; value=kib($4,$5)}
        END {if(n==1) print value; else exit 1}
        ' "$1" || candidate_fail 'unknown APK size summary; cannot safely budget flash'
}
candidate_download_kib() {
    plan_file=$1; shift
    if grep -q '^Need to download ' "$plan_file"; then
        candidate_plan_kib "$plan_file" download
    else
        # APK suppresses the line for zero downloads. Only accept that absence
        # when every requested signed prerequisite is already installed; other
        # cached/missing-dependency cases stop rather than assume zero bytes.
        for dep in "$@"; do
            apk info -e "$dep" >/dev/null 2>&1 || candidate_fail 'download size absent for a missing dependency'
        done
        printf '0\n'
    fi
}
candidate_space_required() {
    for n in "$@"; do case "$n" in ''|*[!0-9]*) candidate_fail 'invalid size input' ;; esac; done
    # Solver installed growth + two complete payload allowances (installed and
    # versioned UI) + actual checkpoint + runtime backup + download-cache bound
    # + 4 MiB journal/filesystem/headroom. No compressed pinned APKs on flash.
    printf '%s\n' "$(( $1 + 2*$2 + $3 + $4 + $5 + 4096 ))"
}
candidate_space_check() {
    printf 'Persistent space: available=%s KiB, calculated-required=%s KiB\n' "$1" "$2"
    [ "$1" -ge "$2" ] || candidate_fail 'calculated persistent space insufficient; no package/config changes made'
}
candidate_existing_backup_kib() {
    # Pinned adapter backup lists; only inspect pre-existing paths. The future
    # stock Podkop/LuCI files add <1 MiB; engine ELF is not backed up by adapter.
    sed -n -e '/^RUNTIME_FILES="$/,/^"$/p' -e '/^PERSISTENT_PATHS="$/,/^"$/p' "$work/pe-install.sh" |
        sed '/="$/d; /^"$/d; /^$/d' > "$work/backup-paths"
    [ "$(wc -l < "$work/backup-paths")" -ge 20 ] || candidate_fail 'adapter backup list missing'
    : > "$work/backup-sizes"
    while IFS= read -r rel; do
        case "$rel" in ''|/*|*..*|*[!a-zA-Z0-9_./-]*) candidate_fail 'invalid adapter backup path' ;; esac
        if [ -e "/$rel" ] || [ -L "/$rel" ]; then du -sk "/$rel" >> "$work/backup-sizes" || candidate_fail 'cannot measure existing backup path'; fi
    done < "$work/backup-paths"
    awk '{sum+=$1} END {print sum+1024}' "$work/backup-sizes"
}
candidate_package_version() {
    listing=$(apk list --installed --manifest 2>/dev/null) || candidate_fail 'installed APK database query failed'
    printf '%s\n' "$listing" | awk -v p="$1" '$1==p {n++; v=$2} END {if(n>1 || (n==1 && v=="")) exit 1; if(n==1) print v}' ||
        candidate_fail 'duplicate or malformed installed package identity'
}
candidate_engine_features() {
    output=$(/usr/bin/sing-box version) || candidate_fail 'engine version failed'
    printf '%s\n' "$output" | grep -Fx 'sing-box version 1.14.2-pdk-r14' >/dev/null || candidate_fail 'wrong engine identity'
    for feature in urltest.fallbacks urltest.download_url transport.xhttp tools.decode-link tls.utls-fallback; do
        printf '%s\n' "$output" | sed -n 's/^Features:[[:space:]]*//p' | tr ',' '\n' | grep -Fx "$feature" >/dev/null || candidate_fail "missing feature: $feature"
    done
}
candidate_account_check() {
    awk -F: '($1=="sing-box" && ($3!=5566 || $4!=5566)) || ($3==5566 && $1!="sing-box") {exit 1}' "$1" || candidate_fail 'sing-box UID conflict'
    awk -F: '($1=="sing-box" && $3!=5566) || ($3==5566 && $1!="sing-box") {exit 1}' "$2" || candidate_fail 'sing-box GID conflict'
}
candidate_account_create() {
    candidate_account_check /etc/passwd /etc/group
    IPKG_INSTROOT=''; export IPKG_INSTROOT
    . /lib/functions.sh
    group_exists sing-box || group_add sing-box 5566
    user_exists sing-box || user_add sing-box 5566 5566
    candidate_account_check /etc/passwd /etc/group
    id sing-box >/dev/null || candidate_fail 'service account creation failed'
}
candidate_main() {
    case "${1:-}" in ''|--check) ;; *) candidate_fail 'usage: sh i [--check]' ;; esac
    [ "$(id -u)" = 0 ] || candidate_fail 'root required'
    for tool in apk uci sha256sum ubus tar; do command -v "$tool" >/dev/null 2>&1 || candidate_fail "missing $tool"; done
    . /etc/openwrt_release
    board=$(ubus call system board | sed -n 's/.*"board_name": *"\([^"]*\)".*/\1/p')
    candidate_platform "$DISTRIB_RELEASE" "$DISTRIB_ARCH" "$(apk --print-arch)" "$board"
    pending=$(uci changes) || candidate_fail 'UCI unreadable'
    [ -z "$pending" ] || candidate_fail 'pending UCI edits; not modifying them'
    pv=$(candidate_package_version podkop) || candidate_fail 'cannot identify Podkop package'
    lv=$(candidate_package_version luci-app-podkop) || candidate_fail 'cannot identify LuCI package'
    ev=$(candidate_package_version podkop-engine) || candidate_fail 'cannot identify Engine package'
    mode=$(candidate_mode "$pv" "$lv" "$ev")
    if [ "$mode" = existing ]; then
        candidate_engine_features
        grep -Fq 'PODKOP_SUBSCRIPTIONS_PATCH_VERSION=20261017-pe-fastfix-v1-candidate' /usr/bin/podkop || candidate_fail 'not this installed candidate; separate patch update required'
        printf 'Already installed; no packages or services changed.\n'; return 0
    fi
    for path in /usr/bin/podkop /usr/bin/sing-box /etc/config/podkop /etc/podkop /etc/config/sing-box /etc/sing-box; do
        { [ ! -e "$path" ] && [ ! -L "$path" ]; } || candidate_fail 'saved/unowned state exists; not fresh'
    done
    for pkg in sing-box sing-box-tiny podkop-engine-full https-dns-proxy nextdns luci-app-passwall luci-app-passwall2; do
        ! apk info -e "$pkg" >/dev/null 2>&1 || candidate_fail 'conflicting engine installed'
    done
    candidate_account_check /etc/passwd /etc/group
    [ -r /lib/functions.sh ] || candidate_fail 'OpenWrt account helpers missing'
    printf 'TEST: fresh Podkop 0.7.24 + UNOFFICIAL PE Engine. End state: installed/stopped, NOT active proxy routing.\n'
    [ "${1:-}" != --check ] || return 0
    mem=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ "${mem:-0}" -ge 98304 ] || candidate_fail '96 MiB available RAM required'
    awk '$2=="/tmp" && $3=="tmpfs" {ok=1} END {exit !ok}' /proc/mounts || candidate_fail '/tmp must be RAM-backed tmpfs'
    checkpoint_usage=$(du -sk /etc /lib/apk/db) || candidate_fail 'cannot bound checkpoint staging size'
    checkpoint_bound=$(printf '%s\n' "$checkpoint_usage" | awk '{s+=$1} END {print s}')
    staging_bound=$((32768 + 2*checkpoint_bound))
    tmpfree=$(df -Pk /tmp | awk 'END {print $4}')
    [ "${tmpfree:-0}" -ge "$staging_bound" ] && [ "$mem" -ge "$((98304 + staging_bound))" ] ||
        candidate_fail "RAM staging requires ${staging_bound} KiB tmpfs and 98304 KiB additional memory headroom"
    printf 'Export your firmware/config checkpoint and ensure local LAN/physical recovery. Config backup is NOT package/firmware rollback.\nType INSTALL to confirm the test: '
    IFS= read -r answer || candidate_fail 'confirmation required in terminal'
    [ "$answer" = INSTALL ] || candidate_fail 'cancelled'
    umask 077
    work=$(mktemp -d /tmp/podkop-pe-candidate.XXXXXX)
    printf 'Private RAM staging: %s\n' "$work"
    tar -czf "$work/before.tgz" -C / etc lib/apk/db || candidate_fail 'checkpoint failed'
    tar -tzf "$work/before.tgz" >/dev/null || candidate_fail 'checkpoint invalid'
    sha256sum "$work/before.tgz" > "$work/before.sha256"
    sha256sum -c "$work/before.sha256" || candidate_fail 'checkpoint integrity failed'
    apk list --installed --manifest > "$work/packages.before"
    printf 'Do not restore package DB alone. Use exported firmware checkpoint/local recovery for full rollback.\n' > "$work/RECOVERY.txt"
    commit=c4b67eba6c55d3590556fae13ca09fbce226b207
    [ "${#commit}" = 40 ] || candidate_fail 'cannot pin commit'
    case "$commit" in *[!a-f0-9]*) candidate_fail 'invalid commit' ;; esac
    base=https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$commit
    candidate_fetch "$base/openwrt/pe-install.sh" "$work/pe-install.sh"
    candidate_hash 9ac1fe848b8b0384e93dd4a246f6e16d8c4f72d243a5da724b2b1375b534a183 "$work/pe-install.sh"
    deps='curl jq patch bind-dig coreutils-base64 kmod-nft-tproxy luci-base ca-bundle uhttpd-mod-ubus'
    candidate_simulate "$work/dependencies.plan" $deps
    candidate_fetch https://github.com/itdoginfo/podkop/releases/download/0.7.24/podkop-0.7.24-r1.apk "$work/podkop.apk"
    candidate_hash a444a784a7dc22b2ba17336b773f75b27861daf3fb358fea21b31935a975318e "$work/podkop.apk"
    candidate_fetch https://github.com/itdoginfo/podkop/releases/download/0.7.24/luci-app-podkop-0.7.24-r1.apk "$work/luci.apk"
    candidate_hash 96d662b2f19e514e3486e9cddf545af1ce104d518884e3c61e8f4030c6f52746 "$work/luci.apk"
    candidate_fetch https://github.com/FiyeroT/podkop-engine/releases/download/v1.14.2-r14/podkop-engine_1.14.2-r14_openwrt_aarch64_cortex-a53.apk "$work/engine.apk"
    candidate_hash 8956c62696ee292902960cbdb198339527d5d7946a677cf26616afc8632a1f63 "$work/engine.apk"
    candidate_simulate "$work/full.plan" --allow-untrusted --no-scripts "$work/engine.apk" "$work/podkop.apk" "$work/luci.apk" $deps
    mkdir "$work/openwrt"
    candidate_fetch "$base/openwrt/update-manifest.json" "$work/openwrt/update-manifest.json"
    # Our generated manifest format is parsed without requiring jq bootstrap.
    sed -n 's/^    "\(openwrt\/[a-zA-Z0-9_./-]*\)": "\([a-f0-9]\{64\}\)"[,]*$/\1 \2/p' "$work/openwrt/update-manifest.json" > "$work/assets"
    [ "$(wc -l < "$work/assets")" -ge 50 ] || candidate_fail 'manifest assets incomplete'
    while read -r asset hash; do
        case "$asset" in *..*) candidate_fail 'unsafe manifest path' ;; esac
        mkdir -p "$work/$(dirname "$asset")"
        candidate_fetch "$base/$asset" "$work/$asset"
        candidate_hash "$hash" "$work/$asset"
    done < "$work/assets"
    growth=$(candidate_plan_kib "$work/full.plan" growth) || candidate_fail 'missing installed-size estimate'
    download=$(candidate_download_kib "$work/full.plan" $deps) || candidate_fail 'missing download-size estimate'
    [ "$growth" -ge 22858 ] || candidate_fail 'solver growth below pinned APK installed metadata (23405648 bytes)'
    payload_usage=$(du -sk "$work/openwrt") || candidate_fail 'payload size unreadable'
    payload=$(printf '%s\n' "$payload_usage" | awk '{print $1}')
    checkpoint_usage=$(du -k "$work/before.tgz" "$work/before.sha256" "$work/packages.before" "$work/RECOVERY.txt") || candidate_fail 'checkpoint size unreadable'
    checkpoint_kib=$(printf '%s\n' "$checkpoint_usage" | awk '{s+=$1} END {print s+64}')
    backup_kib=$(candidate_existing_backup_kib) || candidate_fail 'cannot size runtime backup'
    required=$(candidate_space_required "$growth" "$payload" "$checkpoint_kib" "$backup_kib" "$download")
    free=$(df -Pk /root | awk 'END {print $4}')
    printf 'Budget KiB: installed-growth=%s (pinned APK metadata=22858), payload+UI=%s*2, checkpoint=%s, runtime-backup=%s, dependency-download-cache=%s, margin=4096\n' "$growth" "$payload" "$checkpoint_kib" "$backup_kib" "$download"
    candidate_space_check "$free" "$required"
    mem=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ "${mem:-0}" -ge 98304 ] || candidate_fail 'RAM headroom below 96 MiB after staging; nothing installed'
    pending=$(uci changes) || candidate_fail 'UCI unreadable before install'
    [ -z "$pending" ] || candidate_fail 'UCI changed during staging'
    apk list --installed --manifest > "$work/packages.now"
    cmp -s "$work/packages.before" "$work/packages.now" || candidate_fail 'packages changed during staging'
    checkpoint=$(mktemp -d /root/podkop-pe-checkpoint.XXXXXX)
    cp "$work/before.tgz" "$work/packages.before" "$work/RECOVERY.txt" "$checkpoint/"
    sha256sum "$checkpoint/before.tgz" > "$checkpoint/before.sha256"
    sha256sum -c "$checkpoint/before.sha256" || candidate_fail 'persistent checkpoint checksum failed'
    cp "$work/full.plan" "$checkpoint/full.plan"
    printf 'Persistent checkpoint: %s (RAM staging separate)\n' "$checkpoint"
    apk add $deps || candidate_fail "signed dependency install failed; see $work"
    hv=$(candidate_package_version uhttpd) || candidate_fail 'uhttpd version unreadable'
    uv=$(candidate_package_version uhttpd-mod-ubus) || candidate_fail 'uhttpd-mod-ubus version unreadable'
    [ -n "$hv" ] && [ "$hv" = "$uv" ] && [ -f /usr/lib/uhttpd_ubus.so ] || candidate_fail 'matching installed uhttpd/ubus transport required; hidden adapter upgrade refused'
    candidate_simulate "$work/local.plan" --no-network --allow-untrusted --no-scripts "$work/engine.apk" "$work/podkop.apk" "$work/luci.apk"
    # Unsigned permission applies only to this offline local pinned transaction.
    apk --no-network --allow-untrusted --no-scripts add "$work/engine.apk" "$work/podkop.apk" "$work/luci.apk" || candidate_fail "local install failed; see $work"
    mkdir "$checkpoint/deferred-defaults" "$checkpoint/adapter"
    # Do not leave engine uci-defaults to silently activate failsafe on reboot.
    for default in /etc/uci-defaults/99-podkop-engine /etc/uci-defaults/50_luci-podkop; do
        if [ -f "$default" ]; then
            sha256sum "$default" >> "$checkpoint/deferred-defaults/owned-files.sha256"
            mv "$default" "$checkpoint/deferred-defaults/"
        fi
    done
    candidate_engine_features
    candidate_account_create
    manifest_sha=$(sha256sum "$work/openwrt/update-manifest.json" | awk '{print $1}')
    PODKOP_PATCH_VERSION="$commit" PODKOP_PATCH_RAW_BASE="file://$work/openwrt" \
    PODKOP_PATCH_MANIFEST_SHA256="$manifest_sha" PODKOP_PATCH_UPDATE_PODKOP=0 PODKOP_PATCH_BACKUP_ROOT="$checkpoint/adapter" \
    PODKOP_PATCH_FORCE_PODKOP_UPDATE=0 PODKOP_PATCH_DEFER_SERVICE_START=1 \
        sh "$work/pe-install.sh" || candidate_fail "PE adapter failed; checkpoint $checkpoint retained"
    printf 'INSTALLED / STOPPED. Configure subscriptions in LuCI before explicit activation.\nCheckpoint: %s\nRAM staging (lost on reboot): %s\n' "$checkpoint" "$work"
}
# CANDIDATE_MAIN
candidate_main "$@"
