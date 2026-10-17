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
    apk --simulate add "$@" > "$plan" 2>&1 || candidate_fail 'APK dependency/ABI simulation failed; no packages changed'
    if grep -Ei 'upgrad|downgrad|reinstall|replac|purg|remov|break|unsatisf|conflict|ERROR:' "$plan" >/dev/null; then
        candidate_fail 'APK plan alters existing packages or has conflicts'
    fi
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
    free=$(df -Pk /root | awk 'END {print $4}')
    [ "${free:-0}" -ge 98304 ] || candidate_fail "persistent space: available=${free:-0} KiB, required=98304 KiB (96 MiB); no cleanup performed"
    printf 'Export your firmware/config checkpoint and ensure local LAN/physical recovery. Config backup is NOT package/firmware rollback.\nType INSTALL to confirm the test: '
    IFS= read -r answer || candidate_fail 'confirmation required in terminal'
    [ "$answer" = INSTALL ] || candidate_fail 'cancelled'
    umask 077
    work=$(mktemp -d /root/podkop-pe-candidate.XXXXXX)
    printf 'Persistent checkpoint/staging: %s\n' "$work"
    tar -czf "$work/before.tgz" -C / etc lib/apk/db || candidate_fail 'checkpoint failed'
    tar -tzf "$work/before.tgz" >/dev/null || candidate_fail 'checkpoint invalid'
    sha256sum "$work/before.tgz" > "$work/before.sha256"
    sha256sum -c "$work/before.sha256" || candidate_fail 'checkpoint integrity failed'
    apk list --installed --manifest > "$work/packages.before"
    printf 'Do not restore package DB alone. Use exported firmware checkpoint/local recovery for full rollback.\n' > "$work/RECOVERY.txt"
    candidate_fetch https://api.github.com/repos/moz9/podkop-patch-subscriptions/commits/test/redmi-ax6-pe-0724-fastfix "$work/commit.json"
    commit=$(sed -n 's/^  "sha": "\([a-f0-9]*\)",/\1/p' "$work/commit.json" | head -n 1)
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
    pending=$(uci changes) || candidate_fail 'UCI unreadable before install'
    [ -z "$pending" ] || candidate_fail 'UCI changed during staging'
    apk list --installed --manifest > "$work/packages.now"
    cmp -s "$work/packages.before" "$work/packages.now" || candidate_fail 'packages changed during staging'
    apk add $deps || candidate_fail "signed dependency install failed; see $work"
    hv=$(candidate_package_version uhttpd) || candidate_fail 'uhttpd version unreadable'
    uv=$(candidate_package_version uhttpd-mod-ubus) || candidate_fail 'uhttpd-mod-ubus version unreadable'
    [ -n "$hv" ] && [ "$hv" = "$uv" ] && [ -f /usr/lib/uhttpd_ubus.so ] || candidate_fail 'matching installed uhttpd/ubus transport required; hidden adapter upgrade refused'
    candidate_simulate "$work/local.plan" --no-network --allow-untrusted --no-scripts "$work/engine.apk" "$work/podkop.apk" "$work/luci.apk"
    # Unsigned permission applies only to this offline local pinned transaction.
    apk --no-network --allow-untrusted --no-scripts add "$work/engine.apk" "$work/podkop.apk" "$work/luci.apk" || candidate_fail "local install failed; see $work"
    mkdir "$work/deferred-defaults"
    # Do not leave engine uci-defaults to silently activate failsafe on reboot.
    for default in /etc/uci-defaults/99-podkop-engine /etc/uci-defaults/50_luci-podkop; do
        if [ -f "$default" ]; then
            sha256sum "$default" >> "$work/deferred-defaults/owned-files.sha256"
            mv "$default" "$work/deferred-defaults/"
        fi
    done
    candidate_engine_features
    candidate_account_create
    manifest_sha=$(sha256sum "$work/openwrt/update-manifest.json" | awk '{print $1}')
    PODKOP_PATCH_VERSION="$commit" PODKOP_PATCH_RAW_BASE="file://$work/openwrt" \
    PODKOP_PATCH_MANIFEST_SHA256="$manifest_sha" PODKOP_PATCH_UPDATE_PODKOP=0 \
    PODKOP_PATCH_FORCE_PODKOP_UPDATE=0 PODKOP_PATCH_DEFER_SERVICE_START=1 \
        sh "$work/pe-install.sh" || candidate_fail "PE adapter failed; checkpoint $work retained"
    printf 'INSTALLED / STOPPED. Configure subscriptions in LuCI before explicit activation.\nCheckpoint: %s\n' "$work"
}
# CANDIDATE_MAIN
candidate_main "$@"
