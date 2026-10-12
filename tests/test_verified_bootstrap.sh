#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
mkdir "$work/bin" "$work/release"
sed -n '/^```sh$/,/^```$/p' "$repo/docs/verified-bootstrap.md" | sed '1d;$d' > "$work/bootstrap"
[ -s "$work/bootstrap" ] || { echo 'FAIL: missing bootstrap recipe'; exit 1; }
sh -n "$work/bootstrap"
printf '{"fixture":true}\n' > "$work/release/manifest.json"
cat > "$work/release/i" <<'INSTALLER'
#!/bin/sh
[ "$PODKOP_PATCH_RAW_BASE" = "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$RELEASE_COMMIT/openwrt" ] || exit 9
[ "$PODKOP_PATCH_MANIFEST_SHA256" = "$EXPECTED_MANIFEST_SHA256" ] || exit 9
printf 'verified fixture only\n' >> "$BOOTSTRAP_FIXTURE/executed"
INSTALLER
cat > "$work/bin/curl" <<'CURL'
#!/bin/sh
set -eu
case "$*" in *"--proto =https --proto-redir =https --tlsv1.2"*) ;; *) exit 9;; esac
source='';dest=''
while [ "$#" -gt 0 ]; do
 case "$1" in
  https://*) case "$1" in
   "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$RELEASE_COMMIT/openwrt/update-manifest.json") source=manifest.json;;
   "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$RELEASE_COMMIT/i") source=i;;
   *) exit 9;; esac;;
  -o) shift;dest="$1";;
 esac
 shift
done
[ -n "$source" ] && [ -n "$dest" ] || exit 9
printf '%s\n' "$source" >> "$BOOTSTRAP_FIXTURE/downloads"
cp "$BOOTSTRAP_FIXTURE/release/$source" "$dest"
CURL
chmod +x "$work/bin/curl"
export BOOTSTRAP_FIXTURE="$work" PATH="$work/bin:$PATH"
export RELEASE_COMMIT=0123456789abcdef0123456789abcdef01234567
export EXPECTED_MANIFEST_SHA256="$(sha256sum "$work/release/manifest.json" | cut -d' ' -f1)"
export EXPECTED_INSTALLER_SHA256="$(sha256sum "$work/release/i" | cut -d' ' -f1)"
if EXPECTED_MANIFEST_SHA256="$(printf '%064d' 0)" sh "$work/bootstrap" >/dev/null 2>&1; then echo 'FAIL: wrong manifest accepted'; exit 1; fi
[ ! -e "$work/executed" ] && [ "$(cat "$work/downloads")" = manifest.json ] || exit 1
: > "$work/downloads"
if EXPECTED_INSTALLER_SHA256="$(printf '%064d' 0)" sh "$work/bootstrap" >/dev/null 2>&1; then echo 'FAIL: wrong installer accepted'; exit 1; fi
[ ! -e "$work/executed" ] || exit 1
sh "$work/bootstrap" >/dev/null
[ "$(cat "$work/executed")" = 'verified fixture only' ] || exit 1
printf 'PASS: documented bootstrap authenticates manifest and installer before executing only the pinned fixture\n'
