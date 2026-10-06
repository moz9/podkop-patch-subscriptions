#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM
sed -e 's/\r$//' -e '/^tmp_dir="$(mktemp -d)"$/,$d' "$repo_root/i" > "$test_root/library"
. "$test_root/library"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# OpenWrt can compile jq without ONIGURUMA. Refuse regex builtins in this
# boundary fixture while executing every other operation with the real jq.
PE_REAL_JQ="$(command -v jq)"
export PE_REAL_JQ
mkdir -p "$test_root/no-regex-bin"
cat > "$test_root/no-regex-bin/jq" <<'JQ_EOF'
#!/bin/sh
for argument in "$@"; do
    case "$argument" in *'test('*|*'match('*|*'sub('*|*'gsub('*) printf 'jq built without ONIGURUMA\n' >&2; exit 5 ;; esac
done
exec "$PE_REAL_JQ" "$@"
JQ_EOF
chmod +x "$test_root/no-regex-bin/jq"
PATH="$test_root/no-regex-bin:$PATH"
export PATH
[ "$PATCH_VERSION" = podkop-pe ] || fail_test 'installer defaults to normal channel'
[ "$PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS" = 0.7.23 ] || fail_test 'PE channel accepts older runtime'
grep -q '/commits/podkop-pe' "$repo_root/a" || fail_test 'full stack resolves normal main'
grep -q '/podkop-pe/openwrt/update-manifest.json' "$repo_root/openwrt/podkop-update-manager" || fail_test 'update center follows normal main'
tmp_dir="$test_root/assets"
mkdir -p "$tmp_dir"
download() {
    case "$1" in */update-manifest.json) printf '{"schemaVersion":1,"patchVersion":"20261007-pe-v4","channel":"podkop-pe","sha256":{}}\n' > "$2" ;; *) printf 'payload\n' > "$2" ;; esac
}
prefetch_patch_assets
for asset in podkop.runtime-0.7.23 podkop.js.runtime-0.7.23 helpers.sh sing_box_config_facade.sh sing_box_config_manager.sh podkop-dns-benchmark dns_benchmark.js; do
    [ -s "$tmp_dir/$asset" ] || fail_test "PE asset missing: $asset"
done
command -v verify_patch_download >/dev/null 2>&1 || fail_test 'no release checksum guard'
PATCH_ASSET_MANIFEST="$tmp_dir/update-manifest.json"
if (verify_patch_download "$RAW_BASE/runtime-0.7.23/usr/bin/podkop" "$tmp_dir/podkop.runtime-0.7.23") > "$test_root/missing-checksum-error" 2>&1; then fail_test 'missing PE asset checksum accepted'; fi
grep -q 'release checksum is missing' "$test_root/missing-checksum-error" || fail_test 'wrong missing checksum refusal'
PATCH_ASSET_MANIFEST=
# The real local downloader must enforce the guard, not only its helper.
mkdir -p "$test_root/local"
printf 'release\n' > "$test_root/local/runtime"
runtime_hash="$(sha256sum "$test_root/local/runtime" | awk '{print $1}')"
printf '{"sha256":{"openwrt/runtime":"%s"}}\n' "$runtime_hash" > "$test_root/local/manifest.json"
(
    . "$test_root/library"
    RAW_BASE="file://$test_root/local"
    PATCH_ASSET_MANIFEST="$test_root/local/manifest.json"
    download "$RAW_BASE/runtime" "$test_root/verified"
)
cmp -s "$test_root/local/runtime" "$test_root/verified" || fail_test 'verified local payload changed'
(
    sed -e 's/\r$//' -e '/^# Fetch only known files/,$d' "$repo_root/s" > "$test_root/s-library"
    . "$test_root/s-library"
    MANIFEST="$test_root/local/manifest.json"
    verify_release_file openwrt/runtime "$test_root/local/runtime"
)
printf 'tampered\n' > "$test_root/local/runtime"
if (
    . "$test_root/library"
    RAW_BASE="file://$test_root/local"
    PATCH_ASSET_MANIFEST="$test_root/local/manifest.json"
    download "$RAW_BASE/runtime" "$test_root/refused"
) > "$test_root/checksum-error" 2>&1; then fail_test 'real downloader accepted tampered release'; fi
grep -q 'release checksum mismatch for runtime' "$test_root/checksum-error" || fail_test 'wrong download failure'
if (
    . "$test_root/s-library"
    MANIFEST="$test_root/local/manifest.json"
    verify_release_file openwrt/runtime "$test_root/local/runtime"
) > "$test_root/s-checksum-error" 2>&1; then fail_test 'safe updater accepted tampered asset'; fi
grep -q 'release checksum mismatch' "$test_root/s-checksum-error" || fail_test 'wrong safe updater refusal'
invalid_hex="$(printf '%064d' 0 | tr 0 g)"
printf '{"sha256":{"openwrt/runtime":"%s"}}\n' "$invalid_hex" > "$test_root/local/manifest.json"
if (
    . "$test_root/library"
    RAW_BASE="file://$test_root/local"
    PATCH_ASSET_MANIFEST="$test_root/local/manifest.json"
    download "$RAW_BASE/runtime" "$test_root/invalid-hex"
) > "$test_root/invalid-hex-error" 2>&1; then fail_test 'nonhex checksum accepted'; fi
grep -q 'release checksum is invalid for runtime' "$test_root/invalid-hex-error" || fail_test 'nonhex checksum did not fail charset validation'
if (
    . "$test_root/s-library"
    MANIFEST="$test_root/local/manifest.json"
    verify_release_file openwrt/runtime "$test_root/local/runtime"
) > "$test_root/s-invalid-hex-error" 2>&1; then fail_test 'safe updater nonhex checksum accepted'; fi
grep -q 'release checksum is invalid' "$test_root/s-invalid-hex-error" || fail_test 'safe updater charset guard missing'
if grep -q 'podkop.runtime-0.7.2[02]' "$repo_root/i"; then fail_test 'installer still uses old retrofit sources'; fi
pe_engine_version_output() { printf 'sing-box version 1.13.21-pdk-r11\nFeatures: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link\n'; }
pe_engine_usable || fail_test 'r11 engine rejected'
pe_engine_version_output() { printf 'sing-box version 1.13.21-pdk-r10\nFeatures: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link\n'; }
if pe_engine_usable; then fail_test 'r10 engine accepted'; fi
pe_engine_version_output() { printf 'sing-box version 1.13.21-pdk-r11\nFeatures: urltest.fallbacks,transport.xhttp,tools.decode-link\n'; }
if pe_engine_usable; then fail_test 'missing download_url accepted'; fi
pe_engine_version_output() { printf 'sing-box version 1.13.20-pdk-r11\nFeatures: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link\n'; }
if pe_engine_usable; then fail_test 'outdated engine accepted'; fi
pe_engine_version_output() { printf 'sing-box version 1.14.0-pdk-r11\nFeatures: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link\n'; }
pe_engine_usable || fail_test 'newer compatible PE engine rejected'
printf "DISTRIB_ARCH='mips_24kc'\n" > "$test_root/release"
PE_OPENWRT_RELEASE_FILE="$test_root/release"
if (pe_preflight) > "$test_root/arch-error" 2>&1; then fail_test 'unsupported architecture accepted'; fi
grep -q 'only aarch64_cortex-a53; no changes made' "$test_root/arch-error" || fail_test 'wrong architecture refusal'
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$test_root/release"
apk() { [ "$*" = '--print-arch' ] && { printf 'aarch64\n'; return 0; }; printf '%s\n' "$*" >> "$test_root/apk-calls"; }
pe_preflight
printf 'corrupt\n' > "$test_root/bad.apk"
download() { cp "$test_root/bad.apk" "$2"; }
if (pe_fetch_verified_package https://example.invalid/package "$test_root/download.apk" 822fd8b821614bbdb2f42c9e91d0c8d86d7288a46a10a88fa73cddebcf0209a0) > "$test_root/package-error" 2>&1; then
    fail_test 'package hash mismatch accepted'
fi
grep -q 'pinned package SHA-256 mismatch' "$test_root/package-error" || fail_test 'wrong package checksum refusal'
pe_fetch_verified_package() { printf '%s\n' "$2" >> "$test_root/fetch-calls"; printf 'package\n' > "$2"; }
pe_install_pinned_packages
grep -q '^add --allow-untrusted .*podkop-engine.*podkop-0.7.23-r1.apk.*luci-app-podkop-0.7.23-r1.apk' "$test_root/apk-calls" || fail_test 'fresh install is not a joint dependency transaction'
if (
    . "$test_root/library"
    tmp_dir="$test_root/assets"
    persistent_backup_dir=''; backup_dir=''
    restore_on_fail=0; transaction_phase=preflight
    current_podkop_version() { printf '0.7.23\n'; }
    podkop_packages_match_runtime() { return 0; }
    podkop_persistent_state_exists() { return 1; }
    pe_engine_version_output() { printf 'sing-box version 1.13.21\nFeatures: ordinary\n'; }
    uci() { return 0; }
    pe_install_pinned_packages() { printf 'installed\n' > "$test_root/package-step"; }
    update_official_podkop_if_requested
) > "$test_root/engine-error" 2>&1; then fail_test 'unusable installed engine accepted'; fi
[ -s "$test_root/package-step" ] || fail_test 'engine transaction was not attempted'
grep -q 'installed engine lacks PE r11 features; runtime was not replaced' "$test_root/engine-error" || fail_test 'wrong engine transaction rejection'

run_web_case() {
    web_case="$test_root/web-$1"
    mkdir -p "$web_case/backups"
    (
        . "$test_root/library"
        LUCI_UHTTPD_CONFIG_FILE="$web_case/config"
        LUCI_UHTTPD_UBUS_MODULE="$web_case/module.so"
        BACKUP_ROOT="$web_case/backups"
        backup_dir=''
        printf '%s' "$2" > "$LUCI_UHTTPD_CONFIG_FILE"
        cp "$LUCI_UHTTPD_CONFIG_FILE" "$web_case/original"
        [ "$3" != installed ] || : > "$LUCI_UHTTPD_UBUS_MODULE"
        WEB_PENDING="${4:-}"; WEB_INSTALL_FAIL="${5:-0}"; WEB_RESTART_FAIL="${6:-0}"
        WEB_MODULE_VERSION="${7:-1}"
        installed_package_version() { case "$1" in uhttpd|luci-app-podkop) printf '1\n';; *) [ -e "$LUCI_UHTTPD_UBUS_MODULE" ] && printf '%s\n' "$WEB_MODULE_VERSION";; esac; }
        apk() {
            printf '%s\n' "$*" >> "$web_case/packages"
            [ "$WEB_INSTALL_FAIL" = 0 ] || return 1
            : > "$LUCI_UHTTPD_UBUS_MODULE"
            WEB_MODULE_VERSION=1
        }
        uci() {
            case "$*" in
                changes) printf '%s' "$WEB_PENDING";;
                '-q get uhttpd.main') printf 'uhttpd\n';;
                '-q get uhttpd.main.ubus_prefix') [ -s "$LUCI_UHTTPD_CONFIG_FILE" ] && cat "$LUCI_UHTTPD_CONFIG_FILE";;
                'set uhttpd.main.ubus_prefix=/ubus') printf '/ubus' > "$web_case/stage"; printf 'set\n' >> "$web_case/uci-writes";;
                'commit uhttpd') cp "$web_case/stage" "$LUCI_UHTTPD_CONFIG_FILE"; printf 'commit\n' >> "$web_case/uci-writes";;
                'revert uhttpd') rm -f "$web_case/stage";;
                *) return 1;;
            esac
        }
        restart_luci_web_service() { printf 'restart\n' >> "$web_case/restarts"; [ "$WEB_RESTART_FAIL" = 0 ]; }
        ensure_luci_ubus_transport
    ) > "$web_case/output" 2>&1
}
run_web_case fresh '' missing || fail_test 'LuCI ubus transport not bootstrapped'
grep -Fxq 'add --upgrade uhttpd uhttpd-mod-ubus' "$web_case/packages" || fail_test 'uhttpd/module dependency not installed as a compatible pair'
[ "$(cat "$web_case/config")" = /ubus ] || fail_test 'standard ubus prefix missing'
[ "$(wc -l < "$web_case/restarts")" -eq 1 ] || fail_test 'web service not restarted exactly once'
run_web_case custom /custom-rpc installed || fail_test 'custom ubus prefix rejected'
[ "$(cat "$web_case/config")" = /custom-rpc ] && [ ! -e "$web_case/packages" ] && [ ! -e "$web_case/uci-writes" ] && [ ! -e "$web_case/restarts" ] || fail_test 'custom working transport was changed'
run_web_case custom_missing /custom-rpc missing || fail_test 'custom ubus module not installed'
[ "$(cat "$web_case/config")" = /custom-rpc ] && [ ! -e "$web_case/uci-writes" ] || fail_test 'custom prefix overwritten when module installed'
run_web_case mismatched /ubus installed '' 0 0 0 || fail_test 'mismatched uhttpd/module versions not repaired'
grep -Fxq 'add --upgrade uhttpd uhttpd-mod-ubus' "$web_case/packages" || fail_test 'mismatched module/server pair was not aligned jointly'
[ ! -e "$web_case/uci-writes" ] || fail_test 'pair alignment rewrote an existing prefix'
if run_web_case pending '' missing 'network.lan.ipaddr=192.0.2.1'; then fail_test 'web prerequisite accepted pending UCI'; fi
[ ! -e "$web_case/packages" ] && [ ! -e "$web_case/uci-writes" ] || fail_test 'pending UCI allowed web mutation'
if run_web_case package_failure '' missing '' 1; then fail_test 'failed web dependency accepted'; fi
[ ! -e "$web_case/uci-writes" ] && [ ! -e "$web_case/restarts" ] || fail_test 'failed web dependency changed service/config'
if run_web_case restart_failure '' installed '' 0 1; then fail_test 'failed web restart accepted'; fi
cmp -s "$web_case/config" "$web_case/original" || fail_test 'failed web restart did not restore config'
run_web_case noop /ubus installed || fail_test 'valid ubus transport rejected'
[ ! -e "$web_case/packages" ] && [ ! -e "$web_case/uci-writes" ] && [ ! -e "$web_case/restarts" ] || fail_test 'valid ubus transport not idempotent'
(
    . "$test_root/library"
    installed_package_version() { return 1; }
    ensure_luci_ubus_transport
) || fail_test 'alternative LuCI web server was not left alone'
grep -q '^ensure_luci_ubus_transport$' "$repo_root/i" || fail_test 'main installer does not enforce LuCI transport dependency'
printf 'PASS: PE installer preflight, assets, engine contract and package transaction\n'
