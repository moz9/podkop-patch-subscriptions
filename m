#!/bin/sh
# Explicit old-Podkop -> PE migration. --check is the default and is read-only
# outside its private /tmp directory. No environment variable bypasses a gate.
set -eu
umask 077
ROOT=/
ENGINE_HASH=822fd8b821614bbdb2f42c9e91d0c8d86d7288a46a10a88fa73cddebcf0209a0
PODKOP_HASH=784993aa190fb8f70bbd91baabc5e6373175ae5f27ccd31729645e7610b124ff
LUCI_HASH=ff39cf4415c350567b6f369133f41cc07f374af5fa9d3ce7d9a518acc7f807a8
STOCK_HASH=6cb86dbf647234cb38adc386fb8438ad609375c352a097247185d69ed7718df4
OLD_PODKOP_HASH=5abf1422f73819d0834fd3ca81ccd55aaa7631e8665dc03e8c0d629811302e27
OLD_LUCI_HASH=72addad80b71a9f44ea64af011c24b405c98b7a2b94751166a5668deeab7ad53
PRESERVE='etc/config/podkop etc/podkop etc/config/network etc/config/firewall etc/config/dhcp etc/config/byedpi etc/config/warp etc/config/zerotier etc/config/sing-box etc/sing-box etc/zerotier var/lib/zerotier-one etc/byedpi etc/warp etc/wireguard'
RUNTIME='usr/bin/podkop usr/bin/sing-box usr/bin/podkop-dns-optimizer usr/bin/podkop-dns-benchmark usr/bin/podkop-dns-failover usr/bin/podkop-update-manager usr/lib/podkop usr/share/luci/menu.d/luci-app-podkop.json usr/share/rpcd/acl.d/luci-app-podkop.json usr/lib/lua/luci/i18n/podkop.ru.lmo www/luci-static/resources/view/podkop etc/init.d/podkop etc/init.d/sing-box etc/init.d/podkop-dns-failover etc/rc.d'

log() { printf '%s\n' "$*"; }
die() { log "ОШИБКА: $*" >&2; exit 1; }
archive_root() { printf '%s\n' "${ROOT:-/}"; }
download() {
    case "$1" in https://*) ;; *) return 1 ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 "$1" -o "$2"
    else
        wget -T 120 -O "$2" "$1"
    fi
}
version() { apk list --installed --manifest 2>/dev/null | awk -v p="$1" '$1==p {print $2; exit}'; }
available_kb() { df -Pk "$1" | awk 'NR>1 {n=$4} END {print n}'; }
require_space() {
    free=$(available_kb "$1")
    case "$free" in ''|*[!0-9]*) die "не удалось определить свободное место: $1" ;; esac
    [ "$free" -ge "$2" ] || die "недостаточно места в $1: нужно $2 КиБ, доступно $free КиБ"
}
idle() {
    changes=$(uci changes 2>/dev/null) || die 'не удалось проверить незафиксированные изменения UCI'
    [ -z "$changes" ] || die 'есть незафиксированные изменения UCI; сначала явно сохраните или отмените их'
    for p in tmp/podkop-subscription-action.lock tmp/podkop-subscription-action.lock.d tmp/podkop-update-manager/lock tmp/podkop-patch-safe-update.pid; do
        [ ! -e "$ROOT/$p" ] || die "Podkop занят ($p); изменений нет"
    done
}
verify_hash() {
    [ "$(sha256sum "$2" | awk '{print $1}')" = "$1" ] || die "не совпадает SHA-256: $(basename "$2")"
}
fetch_release() {
    download "https://api.github.com/repos/moz9/podkop-patch-subscriptions/commits/podkop-pe?t=$(date +%s)" "$work/commit.json" || die 'не удалось определить релиз PE'
    commit=$(jq -er '.sha' "$work/commit.json") || die 'некорректный коммит релиза'
    [ "${#commit}" = 40 ] || die 'некорректная длина коммита релиза'
    case "$commit" in *[!0-9a-f]*) die 'некорректный коммит релиза' ;; esac
    raw="https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$commit"
    mkdir "$work/release" "$work/release/openwrt"
    manifest="$work/release/openwrt/update-manifest.json"
    download "$raw/openwrt/update-manifest.json" "$manifest" || die 'не удалось загрузить манифест релиза'
    jq -e '.schemaVersion==1 and .channel=="podkop-pe" and (.patchVersion|type=="string") and (.sha256|type=="object") and (.sha256.i|type=="string") and (.sha256.m|type=="string")' "$manifest" >/dev/null || die 'некорректный манифест PE'
    patch_version=$(jq -er '.patchVersion' "$manifest")
    case "$patch_version" in ''|*[!a-zA-Z0-9_.-]*) die 'некорректная версия патча' ;; esac
    jq -r '.sha256 | to_entries[] | [.key,.value] | @tsv' "$manifest" > "$work/assets"
    while IFS="$(printf '\t')" read -r rel hash; do
        case "$rel" in i|m|openwrt/*) ;; *) continue ;; esac
        case "$rel" in *..*|*[!a-zA-Z0-9_./-]*) die 'небезопасный путь файла релиза' ;; esac
        [ "${#hash}" = 64 ] || die "некорректная контрольная сумма $rel"
        case "$hash" in *[!0-9a-f]*) die "некорректная контрольная сумма $rel" ;; esac
        mkdir -p "$work/release/$(dirname "$rel")"
        download "$raw/$rel" "$work/release/$rel" || die "не удалось загрузить файл релиза: $rel"
        verify_hash "$hash" "$work/release/$rel"
    done < "$work/assets"
    sh -n "$work/release/i" || die 'ошибка синтаксиса установщика'
    grep -Fq 'PODKOP_PATCH_DEFER_SERVICE_START' "$work/release/i" || die 'релиз PE ещё не поддерживает безопасное отложенное включение; сначала опубликуйте актуальный релиз'
}
fetch_new() {
    mkdir "$work/new"
    engine=podkop-engine_1.13.21-r11_openwrt_aarch64_cortex-a53.apk
    pk='podkop-0.7.23-r1.apk'; luci='luci-app-podkop-0.7.23-r1.apk'
    download "https://github.com/FiyeroT/podkop-engine/releases/download/v1.13.21-r11/$engine" "$work/new/$engine" || die 'ядро PE недоступно'
    verify_hash "$ENGINE_HASH" "$work/new/$engine"
    download "https://github.com/itdoginfo/podkop/releases/download/0.7.23/$pk" "$work/new/$pk" || die 'пакет Podkop недоступен'
    verify_hash "$PODKOP_HASH" "$work/new/$pk"
    download "https://github.com/itdoginfo/podkop/releases/download/0.7.23/$luci" "$work/new/$luci" || die 'пакет LuCI недоступен'
    verify_hash "$LUCI_HASH" "$work/new/$luci"
    forward_add --simulate > "$work/forward-plan" 2>&1 || die 'офлайн-проверка установки APK не прошла'
    validate_plan "$work/forward-plan"
}
forward_add() {
    # PE replaces stock sing-box. Keep its installed kernel dependency pinned
    # so APK cannot silently garbage-collect it as an obsolete dependency.
    kernel_diag=$(version kmod-inet-diag)
    if [ -n "$kernel_diag" ]; then
        apk add "$@" --force-non-repository --no-network --no-scripts --allow-untrusted "$work/new/"*.apk "kmod-inet-diag=$kernel_diag"
    else
        apk add "$@" --force-non-repository --no-network --no-scripts --allow-untrusted "$work/new/"*.apk
    fi
}
validate_plan() {
    awk '{for(i=1;i<NF;i++) {if($i ~ /^(Installing|Upgrading|Downgrading|Reinstalling|Purging|Replacing)$/) print $i, $(i+1); else if($i=="Updating" && $(i+1)=="pinning") print "pinning", $(i+2)}}' "$1" > "$work/plan-packages"
    if grep -E '^\([0-9]+/[0-9]+\)' "$1" | grep -Ev ' (Installing|Upgrading|Downgrading|Reinstalling|Purging|Replacing|Updating pinning) ' >/dev/null; then die 'неизвестная операция в плане APK'; fi
    while read -r action p; do
        case "$p:$action" in podkop:*|luci-app-podkop:*|podkop-engine:*|sing-box:*|sing-box-tiny:*|kmod-inet-diag:pinning) ;; *) die "план APK затрагивает посторонний пакет или меняет пакет ядра: $p ($action)" ;; esac
    done < "$work/plan-packages"
}
protected_packages() {
    awk '$1 !~ /^(podkop|luci-app-podkop|podkop-engine|sing-box|sing-box-tiny)$/ {print}' "$1" | sort
}
protected_packages_unchanged() {
    apk list --installed --manifest > "$saved/packages.after" || return 1
    protected_packages "$saved/packages.before" > "$saved/protected.before"
    protected_packages "$saved/packages.after" > "$saved/protected.after"
    cmp -s "$saved/protected.before" "$saved/protected.after"
}
subscription_cache_ready() {
    section_config=$(uci -q show podkop 2>/dev/null) || die 'не удалось прочитать конфигурацию подписок'
    sections=$(printf '%s\n' "$section_config" | sed -n "s/^podkop\.\([^ .]*\)\.proxy_config_type='subscription_urltest'$/\1/p")
    for section in $sections; do
        case "$section" in *[!a-zA-Z0-9_]*) die 'для миграции нужны именованные секции подписок' ;; esac
        hash=$(printf '%s' "$section" | md5sum | awk '{print $1}')
        path="$ROOT/etc/podkop/subscriptions/$hash"
        [ -s "$path.links" ] && [ -s "$path.all.links" ] && [ -s "$path.items.json" ] || die "нет полного офлайн-кеша подписки $section; службы не изменены"
        jq -e 'type=="array" and length>0' "$path.items.json" >/dev/null 2>&1 || die "некорректный кеш узлов подписки $section"
    done
}
service_healthy_once() {
    health=$(ubus call service list '{"name":"sing-box"}' 2>/dev/null) || return 1
    pids=$(printf '%s\n' "$health" | jq -er '."sing-box".instances | to_entries[] | select(.value.running==true) | .value.pid | select(type=="number" and .>0)') || return 1
    [ -n "$pids" ] || return 1
    for pid in $pids; do kill -0 "$pid" 2>/dev/null || return 1; done
}
service_healthy() {
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        service_healthy_once && return 0
        [ "$attempt" -ne 0 ] || log 'Ожидаем регистрации запущенного sing-box в procd...'
        attempt=$((attempt + 1))
        [ "$attempt" -ge 10 ] || sleep 1
    done
    return 1
}
fetch_old() {
    mkdir "$work/old"
    recovery_level=exact-apk
    # Exact packages, not copied binaries or synthetic package-db records.
    # If unavailable, try the independently pinned approved newer stock engine.
    for p in podkop luci-app-podkop "$stock"; do
        v=$(version "$p")
        [ -n "$v" ] || die "отсутствует установленный пакет: $p"
        printf '%s %s\n' "$p" "$v" >> "$work/old-versions"
        if ! apk fetch --output "$work/old" "$p=$v" > "$work/fetch-$p.log" 2>&1; then recovery_level=snapshot-only; fi
    done
    set -- "$work/old/"*.apk
    if [ "$recovery_level" = exact-apk ]; then
        [ -f "$1" ] || recovery_level=snapshot-only
        apk verify "$@" > "$work/old-verify.log" 2>&1 || recovery_level=snapshot-only
        apk add --simulate --no-network --no-scripts "$@" > "$work/rollback-plan" 2>&1 || recovery_level=snapshot-only
    fi
    if [ "$recovery_level" != exact-apk ] && [ "$(version podkop)" = 0.7.22-r1 ] && [ "$(version luci-app-podkop)" = 0.7.22-r1 ] && [ "$stock" = sing-box ]; then
        fetch_approved_stock_recovery
    fi
    log "Уровень восстановления: $recovery_level"
    if [ "$recovery_level" = snapshot-only ]; then
        log 'ВНИМАНИЕ: точные старые APK недоступны. Копия сохраняет настройки, но не гарантирует откат пакетов. При ошибке Podkop останется остановлен; --resume КОПИЯ продолжит миграцию без сети.'
    fi
}
fetch_approved_stock_recovery() {
    mkdir "$work/approved-stock"
    oldroot=https://github.com/itdoginfo/podkop/releases/download/0.7.22
    download "$oldroot/podkop-0.7.22-r1.apk" "$work/approved-stock/podkop-0.7.22-r1.apk" || return 0
    verify_hash "$OLD_PODKOP_HASH" "$work/approved-stock/podkop-0.7.22-r1.apk"
    download "$oldroot/luci-app-podkop-0.7.22-r1.apk" "$work/approved-stock/luci-app-podkop-0.7.22-r1.apk" || return 0
    verify_hash "$OLD_LUCI_HASH" "$work/approved-stock/luci-app-podkop-0.7.22-r1.apk"
    download https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_cortex-a53/packages/sing-box-1.13.21-r1.apk "$work/approved-stock/sing-box-1.13.21-r1.apk" || return 0
    verify_hash "$STOCK_HASH" "$work/approved-stock/sing-box-1.13.21-r1.apk"
    apk verify --allow-untrusted "$work/approved-stock/"*.apk > "$work/approved-verify.log" 2>&1 || die 'не прошла проверка архивов пакетов восстановления'
    mkdir "$work/stock-extracted"
    apk extract --allow-untrusted --destination "$work/stock-extracted" "$work/approved-stock/sing-box-1.13.21-r1.apk" > "$work/extract-stock.log" 2>&1 || die 'не удалось извлечь обычный sing-box'
    [ -f "$ROOT/etc/sing-box/config.json" ] || die 'нет старого конфига sing-box для предварительной проверки отката'
    "$work/stock-extracted/usr/bin/sing-box" version > "$work/stock-version.log" 2>&1 || die 'не удалось запустить обычный sing-box для проверки'
    grep -q '^sing-box version 1.13.21$' "$work/stock-version.log" || die 'неверная версия обычного sing-box'
    "$work/stock-extracted/usr/bin/sing-box" check -c "$ROOT/etc/sing-box/config.json" > "$work/stock-config-check.log" 2>&1 || die 'старый конфиг несовместим с обычным sing-box 1.13.21'
    apk add --simulate --no-network --no-scripts --allow-untrusted "$work/approved-stock/"*.apk > "$work/stock-rollback-plan" 2>&1 || die 'офлайн-план установки обычного sing-box не прошёл'
    validate_plan "$work/stock-rollback-plan"
    for f in "$work/old/"*.apk; do [ ! -f "$f" ] || rm -f "$f"; done
    cp "$work/approved-stock/"*.apk "$work/old/"
    sed 's/^sing-box .*/sing-box 1.13.21-r1/' "$work/old-versions" > "$work/approved-versions"
    mv "$work/approved-versions" "$work/old-versions"
    recovery_level='stock-newer'
    log 'Откат подготовлен: прежний Podkop 0.7.22 и обычный sing-box 1.13.21 вместо прежнего ядра. Старый конфиг проверен до изменений.'
}
paths_existing() {
    for p in $1; do [ ! -e "$ROOT/$p" ] && [ ! -L "$ROOT/$p" ] || printf '%s\n' "$p"; done
}
snapshot() {
    base="$ROOT/root"
    # A directory named /mnt/storage is not evidence that a disk is mounted.
    if [ -r "$ROOT/proc/mounts" ] && awk '$2=="/mnt/storage" {found=1} END {exit !found}' "$ROOT/proc/mounts"; then base="$ROOT/mnt/storage"; fi
    [ -d "$base" ] && [ ! -L "$base" ] || die 'каталог для резервной копии отсутствует или является ссылкой'
    bytes=$(du -sk "$work" | awk '{print $1}')
    needed=$((bytes + 32768))
    for p in $PRESERVE $RUNTIME overlay/upper; do
        if [ -e "$ROOT/$p" ]; then kb=$(du -sk "$ROOT/$p" | awk '{print $1}'); needed=$((needed + kb)); fi
    done
    require_space "$base" "$needed"
    [ ! -L "$base/podkop-pe-migration" ] || die 'каталог резервных копий является ссылкой'
    mkdir -p "$base/podkop-pe-migration"; chmod 700 "$base/podkop-pe-migration"
    saved=$(mktemp -d "$base/podkop-pe-migration/transaction.XXXXXXXX") || die 'не удалось создать постоянную резервную копию'
    cp -a "$work/." "$saved/"
    cp "$saved/release/m" "$saved/migration.sh"; chmod 700 "$saved/migration.sh"
    sh -n "$saved/migration.sh" || die 'скрипт восстановления имеет ошибку синтаксиса'
    paths_existing "$PRESERVE" > "$saved/preserve.paths"
    paths_existing "$RUNTIME" > "$saved/runtime.paths"
    tar -C "$(archive_root)" -cpf "$saved/preserve.tar" -T "$saved/preserve.paths" || die 'не удалось сохранить настройки'
    tar -C "$(archive_root)" -cpf "$saved/runtime.tar" -T "$saved/runtime.paths" || die 'не удалось сохранить runtime'
    if [ -d "$ROOT/overlay/upper" ]; then
        printf '%s\n' overlay/upper/root/podkop-pe-migration > "$saved/overlay.exclude"
        tar -C "$(archive_root)" -X "$saved/overlay.exclude" -cpf "$saved/overlay-upper.tar" overlay/upper || die 'не удалось сохранить весь overlay/upper'
    fi
    apk list --installed --manifest > "$saved/packages.before"
    dns_was_running=0
    if [ -x "$ROOT/etc/init.d/podkop-dns-failover" ]; then
        dns_state=$(ubus call service list '{"name":"podkop-dns-failover"}' 2>/dev/null) || die 'не удалось определить состояние DNS failover перед резервированием'
        if printf '%s\n' "$dns_state" | jq -e '."podkop-dns-failover".instances // {} | any(.[]; .running==true)' >/dev/null; then dns_was_running=1; fi
    fi
    (
        cd "$ROOT/"
        for file in etc/config/podkop etc/config/network etc/config/firewall etc/config/dhcp etc/config/byedpi etc/config/warp etc/config/zerotier etc/zerotier/identity.secret etc/zerotier/identity.public var/lib/zerotier-one/identity.secret var/lib/zerotier-one/identity.public; do
            [ ! -f "$file" ] || sha256sum "$file"
        done
    ) > "$saved/protected-files.sha256" || die 'не удалось вычислить контрольные суммы защищённых настроек'
    (cd "$ROOT/"; [ ! -d etc/podkop ] || find etc/podkop -type f -exec sha256sum '{}' ';') > "$saved/subscription-files.sha256" || die 'не удалось сохранить контрольные суммы кеша подписок'
    [ ! -f "$ROOT/etc/apk/world" ] || cp -a "$ROOT/etc/apk/world" "$saved/world.before"
    printf 'commit=%s\npatch_version=%s\nrecovery_level=%s\ndns_was_running=%s\n' "$commit" "$patch_version" "$recovery_level" "$dns_was_running" > "$saved/metadata"
    (
        cd "$saved"
        sha256sum preserve.tar runtime.tar preserve.paths runtime.paths old-versions metadata packages.before protected-files.sha256 subscription-files.sha256 migration.sh
        [ ! -f world.before ] || sha256sum world.before
        [ ! -f overlay-upper.tar ] || sha256sum overlay-upper.tar
        find release new old -type f | sort | while IFS= read -r file; do sha256sum "$file"; done
    ) > "$saved/frozen.sha256" || die 'не удалось вычислить контрольные суммы резервной копии'
    (cd "$saved" && sha256sum -c frozen.sha256) > "$saved/snapshot-verification.log" 2>&1 || die 'проверка SHA-256 резервной копии не прошла'
    sync || die 'не удалось сбросить резервную копию на диск'
    printf 'prepared\n' > "$saved/status"
    # Never print secret config, identity, subscription URLs, or tar contents.
    log "Проверенная приватная резервная копия: $saved"
    log "Подробный журнал: $saved/migration.log"
    log "Офлайн-откат: sh $saved/migration.sh --rollback $saved"
    work="$saved"
}
restore_preserved() { tar -C "$(archive_root)" -xpf "$saved/preserve.tar"; }
verify_preserved() { (cd "$ROOT/" && sha256sum -c "$saved/protected-files.sha256") > "$saved/protected-verification.log" 2>&1; }
verify_subscription_snapshot() { (cd "$ROOT/" && sha256sum -c "$saved/subscription-files.sha256") > "$saved/subscription-verification.log" 2>&1; }
package_versions_restored() {
    while read -r p v; do [ "$(version "$p")" = "$v" ] || return 1; done < "$saved/old-versions"
    [ -z "$(version podkop-engine)" ]
}
rollback() {
    printf 'rolling-back\n' > "$saved/status"
    log 'Восстанавливаем прежний Podkop и проверенные обычные пакеты без сети...'
    "$ROOT/etc/init.d/podkop" stop >> "$saved/migration.log" 2>&1 || true
    if [ -x "$ROOT/etc/init.d/podkop-dns-failover" ]; then "$ROOT/etc/init.d/podkop-dns-failover" stop >> "$saved/migration.log" 2>&1 || true; fi
    if [ "$recovery_level" = snapshot-only ]; then
        restore_preserved || true
        printf 'recovery-required\n' > "$saved/status"
        log "ОШИБКА: неполная пакетная операция; старый runtime НЕ восстановлен поверх новых пакетов, Podkop остановлен. Продолжение без сети: sh $saved/migration.sh --resume $saved" >&2
        return 1
    fi
    # APK's virtual sing-box dependency can retain PE after `apk del`. The
    # isolated native APK transaction was verified: remove only the explicit
    # PE world constraint, then atomically add old Podkop/LuCI + verified stock.
    world="$ROOT/etc/apk/world"
    if [ -f "$world" ]; then
        cp -a "$world" "$saved/world.recovery-before"
        awk '$0 !~ /^podkop-engine([=<>~].*)?$/ {print}' "$world" > "$saved/world.without-engine"
        cp "$saved/world.without-engine" "$world"
    fi
    if ! recovery_add --simulate > "$saved/rollback-active-plan" 2>&1 || ! (validate_plan "$saved/rollback-active-plan"); then
        [ ! -f "$saved/world.recovery-before" ] || cp -a "$saved/world.recovery-before" "$world"
        printf 'recovery-required\n' > "$saved/status"
        log 'ОШИБКА: план отката не прошёл; Podkop остановлен.' >&2
        return 1
    fi
    if ! recovery_add >> "$saved/migration.log" 2>&1 ||
       ! package_versions_restored || ! protected_packages_unchanged; then
        restore_preserved || true
        printf 'recovery-required\n' > "$saved/status"
        log "ОШИБКА: восстановление пакетов неполное; Podkop остановлен. Копия: $saved" >&2
        return 1
    fi
    if [ "$recovery_level" = stock-newer ]; then
        printf '%s\n' usr/bin/sing-box > "$saved/stock-runtime.exclude"
        tar -C "$(archive_root)" -X "$saved/stock-runtime.exclude" -xpf "$saved/runtime.tar" || { printf 'recovery-required\n' > "$saved/status"; return 1; }
    else
        tar -C "$(archive_root)" -xpf "$saved/runtime.tar" || { printf 'recovery-required\n' > "$saved/status"; return 1; }
    fi
    if ! restore_preserved; then
        printf 'recovery-required\n' > "$saved/status"; return 1
    fi
    if [ -f "$saved/world.before" ]; then
        if [ "$recovery_level" = stock-newer ]; then
            sed 's/^sing-box=[^ ]*/sing-box=1.13.21-r1/' "$saved/world.before" > "$ROOT/etc/apk/world"
        else cp -a "$saved/world.before" "$ROOT/etc/apk/world"; fi
    fi
    if ! verify_subscription_snapshot || ! "$ROOT/usr/bin/sing-box" check -c "$ROOT/etc/sing-box/config.json" >> "$saved/migration.log" 2>&1 ||
       ! PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 "$ROOT/usr/bin/podkop" reload >> "$saved/migration.log" 2>&1; then
        printf 'recovery-required\n' > "$saved/status"; return 1
    fi
    if ! verify_preserved || ! service_healthy; then printf 'recovery-required\n' > "$saved/status"; return 1; fi
    if [ "$dns_was_running" = 1 ] && [ -x "$ROOT/etc/init.d/podkop-dns-failover" ]; then
        "$ROOT/etc/init.d/podkop-dns-failover" start >> "$saved/migration.log" 2>&1 || { printf 'recovery-required\n' > "$saved/status"; return 1; }
    fi
    if [ "$recovery_level" = stock-newer ]; then
        printf 'rolled-back-stock-newer\n' > "$saved/status"
        log "Восстановлен Podkop 0.7.22; обычный sing-box 1.13.21 вместо прежнего ядра; старый конфиг предварительно проверен. Копия: $saved" >&2
    else
        printf 'rolled-back\n' > "$saved/status"
        log "Прежние версии APK и runtime восстановлены; команда запуска успешна. Копия: $saved" >&2
    fi
}
recovery_add() {
    kernel_diag=$(awk '$1=="kmod-inet-diag" {print $2}' "$saved/packages.before")
    if [ -n "$kernel_diag" ]; then
        apk add "$@" --force-non-repository --no-network --no-scripts --allow-untrusted "$saved/old/"*.apk "kmod-inet-diag=$kernel_diag"
    else
        apk add "$@" --force-non-repository --no-network --no-scripts --allow-untrusted "$saved/old/"*.apk
    fi
}
cleanup() {
    rc=$?
    trap - EXIT INT TERM HUP
    if [ "${mutating:-0}" = 1 ]; then rollback || true; rc=1; fi
    if [ "${lock_owned:-0}" = 1 ]; then release_lock; fi
    if [ -n "${temporary:-}" ]; then case "$temporary" in "$ROOT/tmp/podkop-pe-migration."*) rm -rf "$temporary" ;; esac; fi
    exit "$rc"
}
reclaim_stale_locks() {
    # --check never calls this; unknown/empty locks remain fail-closed.
    for file in "$ROOT/tmp/podkop-subscription-action.lock.d/owner" "$ROOT/tmp/podkop-subscription-action.lock"; do
        [ -f "$file" ] || continue
        pid=$(awk 'NR==1 {print $1}' "$file")
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$file"
            case "$file" in */owner) rmdir "$ROOT/tmp/podkop-subscription-action.lock.d" 2>/dev/null || true ;; esac
        fi
    done
}
release_lock() {
    if [ "$(awk 'NR==1 {print $1}' "$ROOT/tmp/podkop-subscription-action.lock.d/owner" 2>/dev/null)" = "$$" ]; then
        rm -f "$ROOT/tmp/podkop-subscription-action.lock.d/owner"
        rmdir "$ROOT/tmp/podkop-subscription-action.lock.d" 2>/dev/null || true
    fi
    if [ "$(awk 'NR==1 {print $1}' "$ROOT/tmp/podkop-subscription-action.lock" 2>/dev/null)" = "$$" ]; then rm -f "$ROOT/tmp/podkop-subscription-action.lock"; fi
    lock_owned=0
}
run_patch() {
    mkdir "$saved/offline-bin"
    # Any unexpected child network/dependency action fails closed. The release
    # has already been verified and every package is installed before this.
    for p in curl wget apk opkg; do
        printf '#!/bin/sh\nprintf "offline migration: %%s disabled\\n" "%s" >&2\nexit 125\n' "$p" > "$saved/offline-bin/$p"
        chmod 700 "$saved/offline-bin/$p"
    done
    # APK reads remain available, writes are denied (including hidden updates).
    real_apk=$(command -v apk)
    case "$real_apk" in /*) ;;
        *) real_apk=/sbin/apk ;; # Shell command doubles in filesystem tests.
    esac
    printf '#!/bin/sh\ncase "$1" in info|list|--print-arch) exec "%s" "$@" ;; *) exit 125 ;; esac\n' "$real_apk" > "$saved/offline-bin/apk"
    env -i PATH="$saved/offline-bin:/usr/sbin:/usr/bin:/sbin:/bin" HOME=/root \
        PODKOP_PATCH_VERSION="$commit" PODKOP_PATCH_RAW_BASE="file://$saved/release/openwrt" \
        PODKOP_PATCH_UPDATE_PODKOP=0 PODKOP_PATCH_FORCE_PODKOP_UPDATE=0 \
        PODKOP_PATCH_BACKUP_ROOT="$saved" PODKOP_PATCH_ACTION_LOCK_DIR="$saved/child.lock" \
        PODKOP_PATCH_ACTION_LOCK_FILE="$saved/child.lock.file" \
        PODKOP_PATCH_PODKOP_INIT_SCRIPT="$saved/no-init" \
        PODKOP_PATCH_DEFER_SERVICE_START=1 \
        sh "$saved/release/i" </dev/null >> "$saved/migration.log" 2>&1
}
engine_pe_ready() {
    output=$("$ROOT/usr/bin/sing-box" version 2>/dev/null) || return 1
    printf '%s\n' "$output" | grep -Fqx 'sing-box version 1.13.21-pdk-r11' || return 1
    for feature in urltest.fallbacks urltest.download_url transport.xhttp tools.decode-link; do
        printf '%s\n' "$output" | sed -n 's/^Features:[[:space:]]*//p' | tr ',' '\n' | grep -Fqx "$feature" || return 1
    done
}
apply_migration() {
    idle
    mkdir "$ROOT/tmp/podkop-subscription-action.lock.d" || die 'одновременно началась другая операция Podkop'
    lock_owned=1
    printf '%s migration %s\n' "$$" "$(date +%s)" > "$ROOT/tmp/podkop-subscription-action.lock.d/owner"
    if ! (set -C; printf '%s migration %s\n' "$$" "$(date +%s)" > "$ROOT/tmp/podkop-subscription-action.lock") 2>/dev/null; then die 'одновременно началась другая операция Podkop'; fi
    [ "$mode" = resume ] || snapshot
    # Repeat pending-UCI check under the maintenance lock immediately before stop.
    changes=$(uci changes 2>/dev/null) || die 'не удалось проверить UCI перед изменениями'
    [ -z "$changes" ] || die 'UCI изменился во время подготовки'
    mutating=1
    printf 'stopping\n' > "$saved/status"
    log 'Резервная копия проверена; останавливаем только Podkop...'
    "$ROOT/etc/init.d/podkop" stop >> "$saved/migration.log" 2>&1 || die 'не удалось остановить Podkop'
    if [ -x "$ROOT/etc/init.d/podkop-dns-failover" ]; then
        log 'Останавливаем прежний DNS failover, чтобы он не включил старый runtime во время смены ядра...'
        "$ROOT/etc/init.d/podkop-dns-failover" stop >> "$saved/migration.log" 2>&1 || die 'не удалось остановить прежний DNS failover'
    fi
    printf 'packages\n' > "$saved/status"
    log 'Устанавливаем заранее проверенные пакеты PE без сети и без post-install запусков...'
    forward_add >> "$saved/migration.log" 2>&1 || die 'ошибка установки пакетов PE'
    protected_packages_unchanged || die 'пакетная операция изменила посторонние пакеты'
    [ "$(version podkop)" = 0.7.23-r1 ] && [ "$(version luci-app-podkop)" = 0.7.23-r1 ] && [ "$(version podkop-engine)" = 1.13.21-r11 ] || die 'установлены неверные версии целевых пакетов'
    engine_pe_ready || die 'установленное ядро не поддерживает функции PE r11'
    restore_preserved || die 'не удалось восстановить настройки после установки пакетов'
    printf 'patching\n' > "$saved/status"
    log 'Применяем проверенные файлы патча PE; настройки будут восстановлены перед запуском...'
    [ ! -d "$saved/offline-bin" ] || rm -f "$saved/offline-bin/curl" "$saved/offline-bin/wget" "$saved/offline-bin/apk" "$saved/offline-bin/opkg"
    [ ! -d "$saved/offline-bin" ] || rmdir "$saved/offline-bin"
    run_patch || die 'ошибка применения патча PE'
    grep -Fq "PODKOP_SUBSCRIPTIONS_PATCH_VERSION=$patch_version" "$ROOT/usr/bin/podkop" || die 'отсутствует маркер текущего релиза PE'
    restore_preserved || die 'не удалось восстановить сохранённые настройки'
    verify_preserved && verify_subscription_snapshot || die 'настройки и кеш подписок не совпадают с сохранённой копией'
    printf 'starting\n' > "$saved/status"
    log 'Настройки восстановлены; запускаем Podkop из локального кеша и проверяем конфиг и процесс...'
    PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 "$ROOT/usr/bin/podkop" reload >> "$saved/migration.log" 2>&1 || die 'не удалось включить исправленный Podkop'
    "$ROOT/usr/bin/sing-box" check -c "$ROOT/etc/sing-box/config.json" >> "$saved/migration.log" 2>&1 || die 'сгенерированный конфиг PE не прошёл проверку'
    verify_preserved || die 'защищённые настройки или идентификатор ZeroTier изменились'
    service_healthy || die 'процесс sing-box не запущен по данным ubus/PID'
    if [ -x "$ROOT/etc/init.d/podkop-dns-failover" ]; then
        "$ROOT/etc/init.d/podkop-dns-failover" enable >> "$saved/migration.log" 2>&1 &&
        "$ROOT/etc/init.d/podkop-dns-failover" restart >> "$saved/migration.log" 2>&1 || die 'не удалось включить DNS failover'
    fi
    printf '%s\n' "$patch_version" > "$saved/installed-patch-version"
    printf 'complete\n' > "$saved/status"
    mutating=0
    log 'Миграция на PE завершена. Сохранённые настройки восстановлены; команда запуска успешна. Внешнее соединение этим не проверено.'
}
main() {
    ROOT=${ROOT%/}
    mode=check
    case "${1:---check}" in --check) ;; --apply) mode=apply ;; --resume) mode=resume ;; --rollback) mode=rollback ;; --help|-h) log "Использование: $0 [--check|--apply|--resume КОПИЯ|--rollback КОПИЯ]. Без аргументов: только проверка. --apply меняет пакеты. --resume продолжает миграцию, --rollback восстанавливает прежний Podkop; оба используют проверенную копию без сети."; return 0 ;; *) die 'неизвестный аргумент; используйте --help' ;; esac
    if [ "$mode" = resume ] || [ "$mode" = rollback ]; then [ "$#" = 2 ] || die 'нужен путь к резервной копии'; else [ "$#" -le 1 ] || die 'лишние аргументы'; fi
    [ "$(id -u)" = 0 ] || die 'нужны права root'
    for p in jq sha256sum md5sum tar awk sed du df uci ubus apk patch base64 cmp sync; do command -v "$p" >/dev/null 2>&1 || die "нужна утилита $p; миграция opkg пока не поддерживается"; done
    [ "$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p" "$ROOT/etc/openwrt_release")" = aarch64_cortex-a53 ] && [ "$(apk --print-arch)" = aarch64 ] || die 'неподдерживаемая архитектура'
    if [ "$mode" = resume ] || [ "$mode" = rollback ]; then
        resume_snapshot "$2"
        return
    fi
    if [ "$(version podkop)" = 0.7.23-r1 ] && [ "$(version luci-app-podkop)" = 0.7.23-r1 ] && [ "$(version podkop-engine)" = 1.13.21-r11 ] && grep -q 'PODKOP_SUBSCRIPTIONS_PATCH_VERSION=' "$ROOT/usr/bin/podkop" && engine_pe_ready; then
        "$ROOT/usr/bin/sing-box" check -c "$ROOT/etc/sing-box/config.json" >/dev/null 2>&1 || die 'конфиг установленного PE не проходит проверку'
        log 'PE уже установлен; конфиг проверен, изменений нет. Обновление версии патча выполняется обычным установщиком i.'; return 0
    fi
    [ -x "$ROOT/etc/init.d/podkop" ] && [ -f "$ROOT/etc/config/podkop" ] || die 'нужен установленный Podkop с настройками'
    [ "$(version podkop)" = 0.7.22-r1 ] && [ "$(version luci-app-podkop)" = 0.7.22-r1 ] || die 'автоматическая миграция пока проверена для Podkop/LuCI 0.7.22-r1; другие версии не изменены'
    web_version=$(version uhttpd)
    if [ -n "$web_version" ]; then
        [ "$(version uhttpd-mod-ubus)" = "$web_version" ] && [ -f "$ROOT/usr/lib/uhttpd_ubus.so" ] || die 'сначала установите совместимые uhttpd и uhttpd-mod-ubus'
        prefix=$(uci -q get uhttpd.main.ubus_prefix 2>/dev/null) || die 'не настроен транспорт LuCI /ubus'
        [ -n "$prefix" ] || die 'не настроен транспорт LuCI /ubus'
    fi
    stock=sing-box
    [ -n "$(version "$stock")" ] || stock=sing-box-tiny
    [ -n "$(version "$stock")" ] || die 'нужен установленный обычный sing-box'
    [ "$mode" != apply ] || reclaim_stale_locks
    idle
    subscription_cache_ready
    require_space "$ROOT/tmp" 80000
    require_space "$ROOT/" 20000
    temporary=$(mktemp -d "$ROOT/tmp/podkop-pe-migration.XXXXXXXX") || die 'не удалось создать приватный каталог подготовки'
    work="$temporary"; saved=; mutating=0; lock_owned=0
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    fetch_release
    fetch_old
    fetch_new
    log "Проверка пройдена: восстановление=$recovery_level; офлайн-план APK проверен, файлы PE $patch_version проверены по SHA-256."
    [ "$mode" = apply ] || return 0
    [ "$recovery_level" != snapshot-only ] || die 'установка отменена: нет проверенного пакетного восстановления; службы не остановлены'
    apply_migration
}
resume_snapshot() {
    [ ! -L "$1" ] && [ -d "$1" ] || die 'резервная копия должна быть каталогом, а не ссылкой'
    saved=$(readlink -f "$1") || die 'не удалось определить путь резервной копии'
    case "$saved" in "$ROOT/root/podkop-pe-migration/transaction."*|"$ROOT/mnt/storage/podkop-pe-migration/transaction."*) ;; *) die 'копия вне каталогов резервирования миграции' ;; esac
    [ "$(find "$saved" -maxdepth 0 -user "$(command id -u)" -perm 0700)" = "$saved" ] || die 'копия должна принадлежать root и иметь права 0700'
    [ -f "$saved/frozen.sha256" ] && [ ! -L "$saved/frozen.sha256" ] || die 'нет записи контрольных сумм копии'
    while read -r hash file; do
        case "$file" in *..*|/*|*[!a-zA-Z0-9_./-]*) die 'небезопасный путь файла резервной копии' ;; esac
        [ ! -L "$saved/$file" ] || die 'файл резервной копии является ссылкой'
        verify_hash "$hash" "$saved/$file"
    done < "$saved/frozen.sha256"
    verify_hash "$ENGINE_HASH" "$saved/new/podkop-engine_1.13.21-r11_openwrt_aarch64_cortex-a53.apk"
    verify_hash "$PODKOP_HASH" "$saved/new/podkop-0.7.23-r1.apk"
    verify_hash "$LUCI_HASH" "$saved/new/luci-app-podkop-0.7.23-r1.apk"
    commit=$(sed -n 's/^commit=//p' "$saved/metadata")
    patch_version=$(sed -n 's/^patch_version=//p' "$saved/metadata")
    recovery_level=$(sed -n 's/^recovery_level=//p' "$saved/metadata")
    dns_was_running=$(sed -n 's/^dns_was_running=//p' "$saved/metadata")
    case "$dns_was_running" in 0|1) ;; *) die 'некорректное исходное состояние DNS failover' ;; esac
    case "$recovery_level" in exact-apk|snapshot-only|stock-newer) ;; *) die 'некорректные данные восстановления' ;; esac
    if [ "$mode" != rollback ]; then [ "$(cat "$saved/status")" != complete ] || { log 'Копия уже отмечена как завершённая; изменений нет.'; return 0; }; fi
    reclaim_stale_locks
    idle
    require_space "$ROOT/" 20000
    temporary=; mutating=0; lock_owned=0; work="$saved"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [ "$mode" = rollback ]; then
        [ "$recovery_level" != snapshot-only ] || die 'в этой копии нет проверенных APK для отката'
        idle
        mkdir "$ROOT/tmp/podkop-subscription-action.lock.d" || die 'одновременно началась другая операция'
        lock_owned=1
        printf '%s migration %s\n' "$$" "$(date +%s)" > "$ROOT/tmp/podkop-subscription-action.lock.d/owner"
        (set -C; printf '%s migration %s\n' "$$" "$(date +%s)" > "$ROOT/tmp/podkop-subscription-action.lock") || die 'занята устаревшая блокировка Podkop'
        rollback || die 'откат неполный; Podkop остановлен, резервная копия сохранена'
        return 0
    fi
    forward_add --simulate > "$saved/resume-plan" 2>&1 || die 'офлайн-проверка продолжения миграции не прошла'
    validate_plan "$saved/resume-plan"
    apply_migration
}
main "$@"
