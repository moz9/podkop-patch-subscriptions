#!/bin/sh
# Free flash by offloading inactive historical backups, never installed services.
set -eu
umask 077
source_root=/root
external_mount=/mnt/storage
mount_table=/proc/mounts

storage_fail() { printf 'Остановлено: %s\n' "$*" >&2; exit 1; }

storage_mount_identity() {
    awk -v p="$external_mount" '$2==p && $3=="ext4" && $4 ~ /^rw[, ]/ {print $1}' "$mount_table"
}

storage_require_disk() {
    [ -n "$external_device" ] && [ "$(storage_mount_identity)" = "$external_device" ] ||
        storage_fail "внешний диск отключён или изменился; оригиналы сохранены"
}

storage_candidate() {
    candidate=$1
    [ -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
    [ "$(dirname "$candidate")" = "$source_root" ] || return 1
    [ "$(readlink -f "$candidate")" = "$candidate" ] || return 1
    case "$(basename "$candidate")" in
        podkop-agh-backup-*.tar.gz|podkop-patch-subscriptions-backup-*|podkop-selection-test.*|podkop-reliability-backup.*|podkop-russian-backup.*|podkop-subscription-apply-v2-backup-*|podkop-before-speedquick-*|router-toolkit-backups) return 0 ;;
        *) return 1 ;;
    esac
}

storage_tree_manifest() {
    tree=$1
    manifest=$2
    paths="$manifest.paths"
    (cd "$tree" && find . -print) > "$paths" || return 1
    LC_ALL=C sort "$paths" > "$paths.sorted" || return 1
    paths="$paths.sorted"
    (
        cd "$tree" || exit 1
        while IFS= read -r entry; do
            # ls is available in minimal OpenWrt builds without stat/diff.
            info=$(ls -ldn "$entry") || exit 1
            permissions=$(printf '%s\n' "$info" | awk '{print $1,$3,$4}')
            printf 'META %s %s\n' "$permissions" "$entry"
            if [ -L "$entry" ]; then
                link=$(readlink "$entry") || exit 1
                printf 'LINK %s %s\n' "$entry" "$link"
            elif [ -f "$entry" ]; then
                sha256sum "$entry" || exit 1
            elif [ ! -d "$entry" ]; then
                exit 1
            fi
        done < "$paths"
    ) > "$manifest"
}

storage_offload() {
    original=$1
    storage_candidate "$original" || storage_fail "путь не входит в список старых копий: $original"
    storage_require_disk
    copied="$backup_root/offloaded/$(basename "$original")"
    [ ! -e "$copied" ] && [ ! -L "$copied" ] || storage_fail "копия уже существует: $copied"
    cp -a "$original" "$copied" || storage_fail "не удалось скопировать $original; оригинал сохранён"
    if [ -d "$original" ]; then
        storage_tree_manifest "$original" "$backup_root/original.manifest" &&
            storage_tree_manifest "$copied" "$backup_root/copied.manifest" &&
            cmp -s "$backup_root/original.manifest" "$backup_root/copied.manifest" ||
            storage_fail "проверка копии не прошла; оригинал сохранён: $original"
    else
        cmp -s "$original" "$copied" || storage_fail "проверка копии не прошла; оригинал сохранён: $original"
    fi
    # Never remove a source until the exact destination has passed comparison.
    storage_candidate "$original" || storage_fail "путь изменился во время копирования"
    storage_idle_path "$original" || storage_fail "копия теперь используется; оригинал сохранён: $original"
    sync || storage_fail "не удалось записать копию на диск; оригинал сохранён"
    storage_require_disk
    rm -r "$original" || storage_fail "копия проверена, но оригинал не удалён: $original"
    printf 'Перенесено: %s → %s\n' "$original" "$copied"
}

storage_idle_path() {
    watched=$1
    # A backup might still be the working directory, executable, open file,
    # or argv of an old watchdog. Any reference is a reason to keep it.
    for link in /proc/[0-9]*/cwd /proc/[0-9]*/exe /proc/[0-9]*/fd/*; do
        resolved=$(readlink "$link" 2>/dev/null || true)
        case "$resolved" in "$watched"|"$watched"/*) return 1 ;; esac
    done
    for command_line in /proc/[0-9]*/cmdline; do
        [ ! -r "$command_line" ] || ! grep -Fq "$watched" "$command_line" || return 1
    done
    # Refuse paths referenced by startup jobs, cron, or a nested mount.
    ! grep -rqF "$watched" /etc/init.d /etc/crontabs /etc/hotplug.d /etc/rc.local 2>/dev/null || return 1
    ! awk -v p="$watched" '$2==p || index($2,p"/")==1 { found=1 } END {exit !found}' /proc/mounts || return 1
}

storage_config_hashes() {
    for config in /etc/config/podkop /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/config/byedpi /etc/config/warp /etc/config/zerotier; do
        [ ! -f "$config" ] || sha256sum "$config"
    done
}

storage_free_kib() { df -Pk /overlay | awk 'NR==2 {print $4}'; }

# ENTRYPOINT
mode=${1:---check}
case "$mode" in
    --help|-h)
        printf 'Подготовка места для PE без удаления сервисов.\n'
        printf 'sh prepare-pe-storage.sh --check  — только отчёт (по умолчанию)\n'
        printf 'sh prepare-pe-storage.sh --apply  — резервная копия и перенос старых снимков на /mnt/storage\n'
        printf 'Не устанавливает PE и не перезапускает сервисы. Переход с 0.7.22 выполняется отдельно.\n'
        exit 0 ;;
    --check|--apply) [ "$#" -le 1 ] || storage_fail "лишние аргументы" ;;
    *) storage_fail "неизвестный режим; используйте --check или --apply" ;;
esac
[ "$(id -u)" = 0 ] || storage_fail "нужен root"
for tool in ubus uci sha256sum cp cmp readlink find df awk tar sort ls sync; do
    command -v "$tool" >/dev/null 2>&1 || storage_fail "нет команды $tool"
done
[ -z "$(uci changes)" ] || storage_fail "сначала сохраните или сбросьте незавершённые изменения LuCI"
external_device=$(storage_mount_identity)
[ -n "$external_device" ] || storage_fail "нужен отдельный доступный для записи ext4-диск $external_mount; запись во флеш вместо диска запрещена"
before_free=$(storage_free_kib)
printf 'Свободно во флеше: %s КиБ\n' "$before_free"
kept=0
selected=0
for item in "$source_root"/podkop-agh-backup-*.tar.gz "$source_root"/podkop-patch-subscriptions-backup-* \
    "$source_root"/podkop-selection-test.* "$source_root"/podkop-reliability-backup.* \
    "$source_root"/podkop-russian-backup.* "$source_root"/podkop-subscription-apply-v2-backup-* \
    "$source_root"/podkop-before-speedquick-* "$source_root"/router-toolkit-backups; do
    storage_candidate "$item" || continue
    if ! storage_idle_path "$item"; then
        printf 'Оставить: %s (используется или найдено упоминание в автозапуске)\n' "$item"
        kept=$((kept+1)); continue
    fi
    printf 'Перенос: %s (%s КиБ логический размер)\n' "$item" "$(du -sk "$item" | awk '{print $1}')"
    selected=$((selected+1))
done
printf 'Кандидатов: %s; защищённых: %s. ByeDPI, WARP, ZeroTier и установленные пакеты не меняются.\n' "$selected" "$kept"
[ "$mode" = --apply ] || exit 0

[ "$selected" -gt 0 ] || { printf 'Нет старых копий для переноса.\n'; exit 0; }
external_free=$(df -Pk "$external_mount" | awk 'NR==2 {print $4}')
# Room for an uncompressed safety copy of overlay plus all relocated snapshots.
needed_external=$(du -sk /overlay/upper | awk '{print $1*2+32768}')
[ "$external_free" -ge "$needed_external" ] || storage_fail "на внешнем диске недостаточно места для безопасной копии"
[ ! -L "$external_mount/.podkop-pe-private" ] || storage_fail "каталог резервных копий не должен быть ссылкой"
mkdir -p "$external_mount/.podkop-pe-private"
chmod 700 "$external_mount/.podkop-pe-private"
backup_root=$(mktemp -d "$external_mount/.podkop-pe-private/preparation-$(date +%Y%m%d-%H%M%S).XXXXXX")
mkdir "$backup_root/offloaded"
baseline=$(storage_config_hashes)
services=$(pidof sing-box zerotier-one ciadpi 2>/dev/null || true)
tar -czf "$backup_root/overlay-before.tar.gz" -C /overlay upper || storage_fail "резервная копия не создана; ничего не очищено"
tar -tzf "$backup_root/overlay-before.tar.gz" >/dev/null || storage_fail "резервная копия повреждена; ничего не очищено"
sha256sum "$backup_root/overlay-before.tar.gz" > "$backup_root/overlay-before.sha256"
printf '%s\n' "$baseline" > "$backup_root/config-before.sha256"
sync || storage_fail "не удалось записать резервную копию; ничего не очищено"
storage_require_disk
printf 'Резервная копия флеша: %s\n' "$backup_root/overlay-before.tar.gz"
for item in "$source_root"/podkop-agh-backup-*.tar.gz "$source_root"/podkop-patch-subscriptions-backup-* \
    "$source_root"/podkop-selection-test.* "$source_root"/podkop-reliability-backup.* \
    "$source_root"/podkop-russian-backup.* "$source_root"/podkop-subscription-apply-v2-backup-* \
    "$source_root"/podkop-before-speedquick-* "$source_root"/router-toolkit-backups; do
    storage_candidate "$item" || continue
    storage_idle_path "$item" || continue
    storage_offload "$item"
done
[ "$baseline" = "$(storage_config_hashes)" ] || storage_fail "настройки изменились во время подготовки; проверьте резервную копию"
[ "$services" = "$(pidof sing-box zerotier-one ciadpi 2>/dev/null || true)" ] || storage_fail "состав процессов изменился во время подготовки"
after_free=$(storage_free_kib)
printf 'Свободно после подготовки: %s КиБ; освобождено: %s КиБ.\n' "$after_free" "$((after_free-before_free))"
printf 'Копии доступны в %s; восстановления копий из /tmp не требуется.\n' "$backup_root"
printf "Для будущей установки патча: PODKOP_PATCH_BACKUP_ROOT='%s'\n" "$external_mount/.podkop-pe-private"
printf 'Подготовка завершена. PE ещё НЕ установлен. Штатный установщик требует отдельного перехода с 0.7.22.\n'
