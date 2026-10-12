#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail_test "missing '$2' in $1"; }
assert_empty() { [ ! -s "$1" ] || fail_test "unexpected child or package mutation in $1"; }

# Source the real implementation but not its final invocation. Every fixture
# replaces only system/network boundaries; preflight and orchestration are real.
sed '/^main "\$@"$/d' "$repo_root/a" > "$test_root/library.sh"
. "$test_root/library.sh"

sha=985195473f626710378668a2b4f024a27c640e7a
mkdir -p "$test_root/fixtures"
printf "DISTRIB_ID='OpenWrt'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$test_root/release"
printf '{"sha":"%s"}\n' "$sha" > "$test_root/fixtures/api"

for name in i byedpi warp zerotier; do
    cat > "$test_root/fixtures/$name" <<'CHILD'
#!/bin/sh
set -eu
case "$0" in */i) name=Podkop ;; */byedpi) name=ByeDPI ;; */warp) name=WARP ;; */zerotier) name=ZeroTier ;; *) exit 99 ;; esac
if [ -t 0 ] || IFS= read -r unexpected; then exit 98; fi
printf '%s\n' "$name" >> "$CASE_DIR/children"
case "$name" in
    Podkop)
        [ "$PODKOP_PATCH_VERSION" = "$EXPECTED_SHA" ] || exit 97
        [ "$PODKOP_PATCH_RAW_BASE" = "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$EXPECTED_SHA/openwrt" ] || exit 97
        [ "$PODKOP_PATCH_UPDATE_PODKOP" = 1 ] && [ "$PODKOP_PATCH_FORCE_PODKOP_UPDATE" = 0 ] || exit 97
        ;;
    ByeDPI)
        [ "$REF" = e28e8ec1419fc0b73f03bf6192c252021ac6792e ] || exit 97
        [ "$ARCHIVE_URL" = "https://github.com/moz9/luci-app-byedpi/archive/$REF.tar.gz" ] || exit 97
        [ "$PODKOP_CONFIGURE" = 1 ] && [ "$PODKOP_RESTART" = 0 ] && [ "$BYEDPI_START" = auto ] || exit 97
        [ "$BYEDPI_AUTO_INSTALL" = 1 ] || exit 97
        ;;
    ZeroTier)
        [ "$ZRS_BASE_URL" = "https://raw.githubusercontent.com/moz9/zerotier-router-support/0946938730624f04f42b30216ad4b698c5502e1f" ] || exit 97
        ;;
esac
[ "${FAIL_CHILD:-}" != "$name" ]
CHILD
done
for name in byedpi warp zerotier; do
    sha256sum "$test_root/fixtures/$name" > "$test_root/fixtures/$name.sha256"
done
[ "$BYEDPI_SHA256" = 5e4c2e9491311c864da9ee2e5edd673e03e2eb9af72c46a247d1212a9693ebf9 ] || fail_test 'ByeDPI pin changed'
[ "$WARP_SHA256" = 515d77116e422b1f83baf398fc798bc7378eed29040925203d3c8a583d54592e ] || fail_test 'WARP pin changed'
[ "$ZEROTIER_SHA256" = 5470d10ed78edc44d3f97feecb40361f0e0470ecc3ed941c7b321abfb489b0cf ] || fail_test 'ZeroTier pin changed'
BYEDPI_SHA256="$(cut -d ' ' -f 1 "$test_root/fixtures/byedpi.sha256")"
WARP_SHA256="$(cut -d ' ' -f 1 "$test_root/fixtures/warp.sha256")"
ZEROTIER_SHA256="$(cut -d ' ' -f 1 "$test_root/fixtures/zerotier.sha256")"
actual_i_hash="$(sha256sum "$test_root/fixtures/i" | cut -d ' ' -f 1)"
printf '{"channel":"podkop-pe","recommendedPodkopVersion":"0.7.23","sha256":{"i":"%s"}}\n' "$actual_i_hash" > "$test_root/fixtures/manifest"

# These functions stand in for external interfaces, not installer logic.
id() { [ "$1" = -u ] || exit 90; printf '%s\n' "${TEST_UID:-0}"; }
uci() { [ "$1" = changes ] || exit 90; [ "${TEST_UCI_ERROR:-0}" = 0 ] || return 1; printf '%s' "${TEST_PENDING:-}"; }
has_cmd() {
    case "$1" in
        apk) [ "${TEST_MANAGER:-apk}" = apk ] ;;
        opkg) [ "${TEST_MANAGER:-apk}" = opkg ] ;;
        jq|curl) [ "${TEST_MISSING:-}" != "$1" ] || [ -e "$CASE_DIR/$1-ready" ] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
package_installed() {
    [ "$1" != zerotier ] || { [ "${TEST_ZT_INSTALLED:-0}" = 1 ]; return; }
    [ "${TEST_MISSING:-}" != "$1" ] || [ -e "$CASE_DIR/$1-ready" ]
}
apk() {
    printf 'apk %s\n' "$*" >> "$CASE_DIR/packages"
    [ "${TEST_PKG_FAIL:-0}" = 0 ] || return 1
    [ "$1" != add ] || : > "$CASE_DIR/$2-ready"
}
opkg() {
    printf 'opkg %s\n' "$*" >> "$CASE_DIR/packages"
    [ "${TEST_PKG_FAIL:-0}" = 0 ] || return 1
    [ "$1" != install ] || : > "$CASE_DIR/$2-ready"
}
download() {
    url=$1 dest=$2
    printf '%s\n' "$url" >> "$CASE_DIR/downloads"
    case "$url" in
        https://api.github.com/repos/moz9/podkop-patch-subscriptions/commits/podkop-pe) source_name=api ;;
        "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$sha/openwrt/update-manifest.json") source_name=manifest ;;
        "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$sha/i") source_name=i ;;
        https://raw.githubusercontent.com/moz9/luci-app-byedpi/e28e8ec1419fc0b73f03bf6192c252021ac6792e/install.sh) source_name=byedpi ;;
        https://raw.githubusercontent.com/moz9/cloudflare-warp-openwrt-podkop/72cfeef7f1838ad991ed6242188621df2691e86a/install-podkop.sh) source_name=warp ;;
        https://raw.githubusercontent.com/moz9/zerotier-router-support/0946938730624f04f42b30216ad4b698c5502e1f/router-direct-install.sh) source_name=zerotier ;;
        *) fail_test "unexpected URL: $url" ;;
    esac
    [ "${TEST_MISSING_DOWNLOAD:-}" != "$source_name" ] || return 1
    if [ "${TEST_BAD_SYNTAX:-}" = "$source_name" ]; then
        printf 'if then\n' > "$dest"
    elif [ "${TEST_BAD_HASH:-}" = "$source_name" ]; then
        printf 'tampered\n' > "$dest"
    elif [ "${TEST_BAD_SHA:-0}" = 1 ] && [ "$source_name" = api ]; then
        printf '{"sha":"main"}\n' > "$dest"
    elif [ "${TEST_BAD_MANIFEST:-0}" = 1 ] && [ "$source_name" = manifest ]; then
        printf '{"sha256":{}}\n' > "$dest"
    elif [ "${TEST_BAD_SYNTAX:-}" = i ] && [ "$source_name" = manifest ]; then
        invalid_hash="$(printf 'if then\n' | sha256sum | cut -d ' ' -f 1)"
        printf '{"channel":"podkop-pe","recommendedPodkopVersion":"0.7.23","sha256":{"i":"%s"}}\n' "$invalid_hash" > "$dest"
    else
        cp "$test_root/fixtures/$source_name" "$dest"
    fi
    if [ "${TEST_BAD_SYNTAX:-}" = "$source_name" ]; then
        invalid_hash="$(sha256sum "$dest" | cut -d ' ' -f 1)"
        case "$source_name" in
            byedpi) BYEDPI_SHA256=$invalid_hash ;;
            warp) WARP_SHA256=$invalid_hash ;;
            zerotier) ZEROTIER_SHA256=$invalid_hash ;;
        esac
    fi
}

run_case() {
    name=$1
    shift
    CASE_DIR="$test_root/case-$name"
    export CASE_DIR EXPECTED_SHA="$sha"
    mkdir -p "$CASE_DIR"
    : > "$CASE_DIR/children"
    : > "$CASE_DIR/packages"
    : > "$CASE_DIR/downloads"
    OPENWRT_RELEASE_FILE="$test_root/release"
    STACK_LOCK_DIR="$CASE_DIR/lock"
    STACK_TMP_TEMPLATE="$CASE_DIR/work.XXXXXX"
    TEST_MANAGER=apk TEST_MISSING= TEST_UID=0 TEST_PENDING= TEST_UCI_ERROR=0
    TEST_PKG_FAIL=0 TEST_BAD_SHA=0 TEST_BAD_HASH= TEST_BAD_MANIFEST=0
    TEST_MISSING_DOWNLOAD= TEST_BAD_SYNTAX= FAIL_CHILD= TEST_ZT_INSTALLED=0
    export OPENWRT_RELEASE_FILE STACK_LOCK_DIR STACK_TMP_TEMPLATE
    for setting in "$@"; do eval "$setting"; done
    export FAIL_CHILD
    if ( main ) > "$CASE_DIR/output" 2>&1; then result=0; else result=$?; fi
}

run_case success
[ "$result" -eq 0 ] || fail_test "successful stack failed: $(cat "$CASE_DIR/output")"
printf 'Podkop\nByeDPI\nWARP\nZeroTier\n' > "$CASE_DIR/expected"
cmp -s "$CASE_DIR/expected" "$CASE_DIR/children" || fail_test 'child order or environment incorrect'
[ ! -d "$STACK_LOCK_DIR" ] || fail_test 'own lock not released'
run_case rerun 'TEST_ZT_INSTALLED=1'
[ "$result" -eq 0 ] || fail_test 'rerun did not complete'
assert_empty "$CASE_DIR/packages"
printf 'Podkop\nByeDPI\nWARP\n' > "$CASE_DIR/expected"
cmp -s "$CASE_DIR/expected" "$CASE_DIR/children" || fail_test 'installed ZeroTier identity was not preserved'
! grep -Eiq 'join|network.?id|default.?route|PODKOP_RESTART=1|BYEDPI_START=1' "$CASE_DIR/downloads" || fail_test 'forced private network or global route'
run_case inherited_disabled 'export PODKOP_PATCH_UPDATE_PODKOP=0 BYEDPI_AUTO_INSTALL=0 PODKOP_PATCH_FORCE_PODKOP_UPDATE=1'
[ "$result" -eq 0 ] || fail_test 'inherited environment disabled requested components or forced an update'
unset PODKOP_PATCH_UPDATE_PODKOP BYEDPI_AUTO_INSTALL PODKOP_PATCH_FORCE_PODKOP_UPDATE

run_case not_root 'TEST_UID=1000'
[ "$result" -ne 0 ] || fail_test 'non-root allowed'
assert_empty "$CASE_DIR/packages"; assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"
printf "DISTRIB_ID='OpenWrt'\nDISTRIB_ARCH='x86_64'\n" > "$test_root/release"
run_case unsupported_arch
[ "$result" -ne 0 ] || fail_test 'unsupported WARP architecture allowed'
assert_empty "$CASE_DIR/packages"; assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"
printf "DISTRIB_ID='Other'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$test_root/release"
run_case wrong_distro
[ "$result" -ne 0 ] || fail_test 'non-OpenWrt marker allowed'
assert_empty "$CASE_DIR/packages"; assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"
printf "DISTRIB_ID='OpenWrt'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$test_root/release"
run_case pending 'TEST_PENDING=network.wan.metric=2'
[ "$result" -ne 0 ] || fail_test 'pending UCI allowed'
assert_empty "$CASE_DIR/packages"; assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"
run_case unreadable_uci 'TEST_UCI_ERROR=1'
[ "$result" -ne 0 ] || fail_test 'unreadable UCI allowed'
assert_empty "$CASE_DIR/packages"; assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"
run_case duplicate_lock 'mkdir "$STACK_LOCK_DIR"'
[ "$result" -ne 0 ] || fail_test 'duplicate lock allowed'
assert_empty "$CASE_DIR/packages"; assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"

for manager in apk opkg; do
    run_case "missing-jq-$manager" "TEST_MANAGER=$manager" 'TEST_MISSING=jq'
    [ "$result" -eq 0 ] || fail_test "missing jq bootstrap failed under $manager"
    assert_contains "$CASE_DIR/packages" "$manager"
    assert_contains "$CASE_DIR/packages" 'jq'
    run_case "package-failure-$manager" "TEST_MANAGER=$manager" 'TEST_MISSING=jq' 'TEST_PKG_FAIL=1'
    [ "$result" -ne 0 ] || fail_test "package failure continued under $manager"
    assert_empty "$CASE_DIR/downloads"; assert_empty "$CASE_DIR/children"
done
run_case missing_ca 'TEST_MISSING=ca-bundle'
[ "$result" -eq 0 ] || fail_test 'missing ca-bundle bootstrap failed'
assert_contains "$CASE_DIR/packages" 'ca-bundle'
run_case missing_curl 'TEST_MISSING=curl'
[ "$result" -eq 0 ] || fail_test 'missing curl bootstrap failed'
assert_contains "$CASE_DIR/packages" 'curl'
run_case no_manager 'TEST_MANAGER=none' 'TEST_MISSING=jq'
[ "$result" -ne 0 ] || fail_test 'no package manager accepted'
assert_empty "$CASE_DIR/children"

for scenario in bad_sha bad_manifest missing_manifest bad_i bad_byedpi bad_warp bad_zerotier syntax_i syntax_byedpi syntax_warp syntax_zerotier; do
    case "$scenario" in
        bad_sha) setting='TEST_BAD_SHA=1' ;;
        bad_manifest) setting='TEST_BAD_MANIFEST=1' ;;
        missing_manifest) setting='TEST_MISSING_DOWNLOAD=manifest' ;;
        bad_*) setting="TEST_BAD_HASH=${scenario#bad_}" ;;
        syntax_*) setting="TEST_BAD_SYNTAX=${scenario#syntax_}" ;;
    esac
    run_case "$scenario" "$setting"
    [ "$result" -ne 0 ] || fail_test "$scenario unexpectedly succeeded"
    assert_empty "$CASE_DIR/children"
done

run_case child_failure 'FAIL_CHILD=ByeDPI'
[ "$result" -ne 0 ] || fail_test 'failed child allowed continuation'
printf 'Podkop\nByeDPI\n' > "$CASE_DIR/expected"
cmp -s "$CASE_DIR/expected" "$CASE_DIR/children" || fail_test 'children continued after ByeDPI failure'
assert_contains "$CASE_DIR/output" 'Podkop'
! grep -Fq 'Установлены все компоненты' "$CASE_DIR/output" || fail_test 'claimed complete stack on failure'
run_case first_child_failure 'FAIL_CHILD=Podkop'
[ "$result" -ne 0 ] || fail_test 'failed first child allowed continuation'
printf 'Podkop\n' > "$CASE_DIR/expected"
cmp -s "$CASE_DIR/expected" "$CASE_DIR/children" || fail_test 'later children ran after Podkop failure'
assert_contains "$CASE_DIR/output" 'Завершены: нет'
assert_contains "$CASE_DIR/output" 'мог быть установлен частично'

printf '%s\n' 'full stack installer tests passed'
