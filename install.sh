#!/bin/sh
# Podkop PE: install with one command on an OpenWrt router.
#
#   wget -qO- https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/pe-release/install.sh | sh
#   wget -qO- https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/pe-release/install.sh | sh -s -- --replace   a Podkop that is already there is replaced, settings are kept
#   wget -qO- https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/pe-release/install.sh | sh -s -- --check     only check that the router is suitable
#
# It reads the release manifest, takes the installer for this router's OpenWrt branch, checks its
# size and SHA-256 against the manifest and runs it. Removal later: podkop-uninstall.
# The whole script is one function: nothing runs until the shell has received all of it.

main() {
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MANIFEST_URL="${PODKOP_PE_MANIFEST_URL:-https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/pe-release/manifest.json}"
say() { printf '%s\n' "$*"; }
die() { say "Ошибка: $*"; rm -f "$M" "$F" 2>/dev/null; exit 1; }
M=/tmp/podkop-pe-manifest.json; F=/tmp/podkop-pe-install.run

[ "$(id -u)" = 0 ] || die "нужны права root"
[ -r /etc/openwrt_release ] || die "это не OpenWrt"
. /etc/openwrt_release
BRANCH="$(printf '%s' "${DISTRIB_RELEASE:-}" | cut -d. -f1,2)"
command -v jsonfilter > /dev/null 2>&1 || die "нет jsonfilter (нужен штатный OpenWrt)"

get() { # get URL FILE
    if command -v curl > /dev/null 2>&1; then curl -fsSL --connect-timeout 10 --max-time 300 --retry 2 -o "$2" "$1"
    else wget -q -T 60 -O "$2" "$1"; fi
}

say "Подкоп PE: читаю сведения о выпуске..."
get "$MANIFEST_URL" "$M" || die "не скачать $MANIFEST_URL (проверьте интернет и время на роутере)"
VERSION="$(jsonfilter -i "$M" -e '@.version')" || die "манифест выпуска не читается"
URL="$(jsonfilter -i "$M" -e "@.installers['$BRANCH'].url" 2>/dev/null)"
SHA="$(jsonfilter -i "$M" -e "@.installers['$BRANCH'].sha256" 2>/dev/null)"
SIZE="$(jsonfilter -i "$M" -e "@.installers['$BRANCH'].size" 2>/dev/null)"
[ -n "$URL" ] && [ "${#SHA}" = 64 ] && [ -n "$SIZE" ] ||
    die "для OpenWrt ${DISTRIB_RELEASE:-?} установщика нет (выпуск $VERSION собран для: $(jsonfilter -i "$M" -e '@.installers' 2>/dev/null | tr -d '{}' | grep -o '"[0-9.]*":' | tr -d '":' | tr '\n' ' '))"
FREE="$(df -k /tmp | awk 'NR==2 {print $4}')"
[ "${FREE:-0}" -ge $(( SIZE / 1024 * 3 )) ] || die "мало памяти в /tmp: свободно $((FREE/1024)) МБ, нужно $((SIZE/1024*3/1024)) МБ"

say "Выпуск $VERSION, OpenWrt $BRANCH: скачиваю установщик ($((SIZE/1024/1024)) МБ)..."
get "$URL" "$F" || die "не скачать $URL"
[ "$(wc -c < "$F")" = "$SIZE" ] && [ "$(sha256sum "$F" | cut -c1-64)" = "$SHA" ] ||
    die "скачанный файл не совпал с манифестом (размер или контрольная сумма): установка не начата"
rm -f "$M"
sh "$F" "$@"; rc=$?
rm -f "$F"
exit "$rc"
}

main "$@"
