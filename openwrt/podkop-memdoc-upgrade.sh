#!/bin/sh
# Patch only the audited firmware function. Caller owns service activation.
set -eu
target="${PODKOP_MEMDOC_TARGET:-/usr/bin/memdoc}"
syntax_shell="${PODKOP_MEMDOC_SHELL:-ash}"
original="$target.podkop-original"
installed="$target.podkop-guarded"
fail() { printf 'memdoc compatibility: %s\n' "$*" >&2; exit 1; }
[ -e "$target" ] || exit 0
[ -f "$target" ] && [ ! -L "$target" ] || fail 'target is not a regular non-symlink file'
for snapshot in "$original" "$installed"; do
    [ ! -L "$snapshot" ] || fail 'backup path is a symlink'
    [ ! -e "$snapshot" ] || [ -f "$snapshot" ] || fail 'backup path is not a regular file'
done
case "${1:-install}" in
    restore)
        [ -f "$original" ] && [ -f "$installed" ] || fail 'rollback snapshots missing'
        cmp -s "$target" "$installed" || fail 'watchdog changed since patch; refusing overwrite'
        cp -p "$original" "$target" || fail 'rollback copy failed'
        exit 0
        ;;
    install) ;;
    *) fail 'expected install or restore';;
esac
if grep -Fq '# podkop_memdoc_guard begin' "$target"; then
    [ -f "$installed" ] && cmp -s "$target" "$installed" || fail 'managed watchdog changed'
    exit 0
fi
if [ -e "$original" ]; then
    cmp -s "$target" "$original" || fail 'existing original snapshot differs'
fi
# Audit the full target function; do not guess at vendor/user variants.
awk '
    /^restart_service_if_running\(\) \{$/ {count++; active=1; next}
    active && /^\}$/ {active=0; if (line!=4) bad=1; next}
    active {
        gsub(/^[ \t]+|[ \t]+$/, ""); line++
        if (line==1 && $0!="SERVICE=$1") bad=1
        if (line==2 && $0!="if [ -e \"$SERVICE\" ] && $SERVICE status | grep -q \"running\"; then") bad=1
        if (line==3 && $0!="$SERVICE restart") bad=1
        if (line==4 && $0!="fi") bad=1
        if (line>4) bad=1
    }
    END {exit (count!=1 || active || bad || line!=4)}
' "$target" || fail 'unsupported watchdog function; no changes made'
tmp="$(mktemp "${target}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
awk '
    {print}
    /^restart_service_if_running\(\) \{$/ {active=1}
    active && /^[ \t]*SERVICE=\$1$/ {
        print "    # podkop_memdoc_guard begin"
        print "    if [ -x /usr/libexec/podkop-memdoc-guard ]; then"
        print "        /usr/libexec/podkop-memdoc-guard \"$SERVICE\" || return 0"
        print "    else"
        print "        [ \"$SERVICE\" != \"$SINGBOX\" ] || return 0"
        print "    fi"
        print "    # podkop_memdoc_guard end"
        active=0
    }
' "$target" > "$tmp"
"$syntax_shell" -n "$tmp" || fail 'patched watchdog syntax invalid'
[ -e "$original" ] || cp -p "$target" "$original"
cp -p "$target" "$installed"
cat "$tmp" > "$installed"
chmod --reference="$target" "$tmp" 2>/dev/null || chmod 755 "$tmp"
mv "$tmp" "$target"
