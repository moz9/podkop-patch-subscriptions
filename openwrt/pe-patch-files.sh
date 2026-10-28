#!/bin/sh
# Fixed-file transaction library. It never invokes packages or live services.
# PT_ROOT is an explicit filesystem root; PT_JOB is a private persistent folder.
pt_allowed() {
    case "$1" in ''|/*|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1;; esac
    case "$1" in
        usr/bin/podkop|usr/bin/podkop-*|usr/lib/podkop/*.sh|usr/libexec/podkop-memdoc-guard|etc/init.d/podkop-section-worker|etc/init.d/podkop-dns-failover|usr/share/podkop/dns-main.json|usr/share/podkop/dns-bootstrap.json|usr/lib/lua/luci/i18n/podkop.ru.lmo|usr/share/rpcd/acl.d/luci-app-podkop.json|usr/share/luci/menu.d/luci-app-podkop.json|www/luci-static/resources/view/podkop/*.js|www/luci-static/resources/view/podkop_patch_*/*.js) return 0;;
        etc/init.d/podkop|etc/init.d/sing-box) return 0;;
        *) return 1;;
    esac
}
pt_parent() (
    p=$1
    pt_allowed "$p" || exit 1
    [ -d "${PT_ROOT:-/}" ] && [ ! -L "${PT_ROOT:-/}" ] && [ "$(readlink -f "${PT_ROOT:-/}")" = "${PT_ROOT:-/}" ] || exit 1
    p=$(dirname "$p")
    while [ "$p" != . ]; do
        [ ! -L "$PT_ROOT/$p" ] && { [ ! -e "$PT_ROOT/$p" ] || [ -d "$PT_ROOT/$p" ]; } || exit 1
        p=$(dirname "$p")
    done
)
pt_metadata() {
    if command -v stat >/dev/null 2>&1; then command stat -c '%u %g %a %h' "$1"; return; fi
    ucode -l fs -e 'let s=fs.lstat(ARGV[0]); if(!s)exit(1); printf("%d %d %o %d\n",s.uid,s.gid,s.mode & 4095,s.nlink);' "$1"
}
pt_validate() (
    [ -d "$PT_JOB" ] && [ ! -L "$PT_JOB" ] && [ "$(readlink -f "$PT_JOB")" = "$PT_JOB" ] || exit 1
    [ -s "$PT_JOB/targets" ] && [ ! -L "$PT_JOB/targets" ] || exit 1
    awk 'NF!=4 || length($1)!=64 || $1~/[^a-f0-9]/ || $2!~/^(644|755)$/ || $4!~/^[0-9]+$/ {bad=1} {if(paths[$3]++ || indexes[$4]++)bad=1} END{exit(bad || NR>128)}' "$PT_JOB/targets" || exit 1
    while read -r hash mode path index; do
        pt_parent "$path" || exit 1
        [ ! -L "$PT_ROOT/$path" ] && { [ ! -e "$PT_ROOT/$path" ] || [ -f "$PT_ROOT/$path" ]; } || exit 1
        [ -f "$PT_JOB/new/$index" ] && [ ! -L "$PT_JOB/new/$index" ] || exit 1
        [ "$(sha256sum "$PT_JOB/new/$index" | cut -d' ' -f1)" = "$hash" ] || exit 1
    done < "$PT_JOB/targets"
)
pt_verify_backup() (
    [ -f "$PT_JOB/backup.sha256" ] && [ ! -L "$PT_JOB/backup.sha256" ] || exit 1
    (cd "$PT_JOB" && sha256sum -c backup.sha256 >/dev/null) || exit 1
    [ -f "$PT_JOB/before.meta" ] && [ -f "$PT_JOB/absent" ] || exit 1
    while IFS="$(printf '\t')" read -r metadata path; do
        pt_allowed "$path" && [ -f "$PT_JOB/old/$path" ] && [ ! -L "$PT_JOB/old/$path" ] || exit 1
        [ "$(pt_metadata "$PT_JOB/old/$path")" = "$metadata" ] || exit 1
    done < "$PT_JOB/before.meta"
    (cd "$PT_JOB/old" && sha256sum -c ../before.sha256 >/dev/null) || exit 1
    count=$(wc -l < "$PT_JOB/targets"); old=$(wc -l < "$PT_JOB/before.meta"); absent=$(wc -l < "$PT_JOB/absent")
    [ "$count" -eq $((old+absent)) ] || exit 1
)
pt_baseline() (
    while IFS="$(printf '\t')" read -r metadata path; do
        pt_parent "$path" && [ -f "$PT_ROOT/$path" ] && [ ! -L "$PT_ROOT/$path" ] || exit 1
        [ "$(pt_metadata "$PT_ROOT/$path")" = "$metadata" ] || exit 1
    done < "$PT_JOB/before.meta"
    (cd "${PT_ROOT:-/}" && sha256sum -c "$PT_JOB/before.sha256" >/dev/null) || exit 1
    while IFS= read -r path; do pt_parent "$path" && [ ! -e "$PT_ROOT/$path" ] && [ ! -L "$PT_ROOT/$path" ] || exit 1; done < "$PT_JOB/absent"
)
pt_capture() (
    pt_validate && [ ! -e "$PT_JOB/old" ] || exit 1
    new_kib=$(du -sk "$PT_JOB/new" | awk '{print $1}')
    old_kib=0
    while read -r hash mode path index; do
        [ ! -f "$PT_ROOT/$path" ] || old_kib=$((old_kib+$(du -k "$PT_ROOT/$path" | awk '{print $1}')))
    done < "$PT_JOB/targets"
    available=$(df -Pk "$PT_JOB" | awk 'NR==2 {print $4}')
    [ "$new_kib" -le 16384 ] && [ "$old_kib" -le 16384 ] && [ "$available" -ge $((old_kib*2+new_kib+8192)) ] || exit 1
    mkdir "$PT_JOB/old" || exit 1
    : > "$PT_JOB/before.sha256"; : > "$PT_JOB/before.meta"; : > "$PT_JOB/absent"
    while read -r hash mode path index; do
        if [ -f "$PT_ROOT/$path" ]; then
            metadata=$(pt_metadata "$PT_ROOT/$path") || exit 1
            # A patch must not break hardlink identity or replace foreign files.
            [ "${metadata%% *}" = "$(id -u)" ] && [ "${metadata##* }" = 1 ] || exit 1
            before=$(sha256sum "$PT_ROOT/$path" | cut -d' ' -f1)
            mkdir -p "$PT_JOB/old/$(dirname "$path")" && cp -p "$PT_ROOT/$path" "$PT_JOB/old/$path" || exit 1
            [ "$(sha256sum "$PT_JOB/old/$path" | cut -d' ' -f1)" = "$before" ] || exit 1
            printf '%s  %s\n' "$before" "$path" >> "$PT_JOB/before.sha256"
            printf '%s\t%s\n' "$metadata" "$path" >> "$PT_JOB/before.meta"
        else printf '%s\n' "$path" >> "$PT_JOB/absent"; fi
    done < "$PT_JOB/targets"
    pt_baseline || exit 1
    (cd "$PT_JOB" && tar -cpf backup.tar old targets before.sha256 before.meta absent && sha256sum backup.tar targets before.sha256 before.meta absent > backup.sha256) || exit 1
    pt_verify_backup && sync
)
pt_receipt() (
    pt_verify_backup || exit 1
    [ "$1" = "$(sha256sum "$PT_JOB/backup.tar"|cut -d' ' -f1)" ] || exit 1
    printf '%s\n' "$1" > "$PT_JOB/pc-receipt"
    sync
)
pt_install() (
    pt_verify_backup && pt_validate && pt_baseline || exit 1
    [ "$(cat "$PT_JOB/pc-receipt" 2>/dev/null)" = "$(sha256sum "$PT_JOB/backup.tar"|cut -d' ' -f1)" ] || exit 1
    while read -r hash mode path index; do
        pt_parent "$path" || exit 1
        mkdir -p "$PT_ROOT/$(dirname "$path")" || exit 1
        next="$PT_ROOT/$path.routerdesk-new"
        [ ! -e "$next" ] && [ ! -L "$next" ] || exit 1
        (set -C; : > "$next") || exit 1
        printf '%s\n' "$path" >> "$PT_JOB/staging-owned" || exit 1
        cp "$PT_JOB/new/$index" "$next" && chmod "$mode" "$next" || exit 1
        [ "$(sha256sum "$next" | cut -d' ' -f1)" = "$hash" ] && mv "$next" "$PT_ROOT/$path" || exit 1
    done < "$PT_JOB/targets"
    sync
)
pt_installed() (
    while read -r hash mode path index; do
        pt_parent "$path" && [ -f "$PT_ROOT/$path" ] && [ ! -L "$PT_ROOT/$path" ] || exit 1
        [ "$(sha256sum "$PT_ROOT/$path"|cut -d' ' -f1)" = "$hash" ] || exit 1
        [ "$(pt_metadata "$PT_ROOT/$path"|awk '{print $3}')" = "$mode" ] || exit 1
    done < "$PT_JOB/targets"
)
pt_restore() (
    pt_verify_backup || exit 1
    while read -r hash mode path index; do
        pt_parent "$path" || exit 1
        [ ! -L "$PT_ROOT/$path" ] && { [ ! -e "$PT_ROOT/$path" ] || [ -f "$PT_ROOT/$path" ]; } || exit 1
        # Only exact allowlisted files can be removed, never a tree.
        if [ -f "$PT_JOB/staging-owned" ] && grep -Fqx "$path" "$PT_JOB/staging-owned"; then rm -f "$PT_ROOT/$path.routerdesk-new" || exit 1; fi
        if grep -Fqx "$path" "$PT_JOB/absent"; then rm -f "$PT_ROOT/$path" || exit 1
        else
            next="$PT_ROOT/$path.routerdesk-restore"
            [ ! -e "$next" ] && [ ! -L "$next" ] || exit 1
            (set -C; : > "$next") && cp -p "$PT_JOB/old/$path" "$next" && mv "$next" "$PT_ROOT/$path" || exit 1
        fi
    done < "$PT_JOB/targets"
    pt_baseline && sync
)
