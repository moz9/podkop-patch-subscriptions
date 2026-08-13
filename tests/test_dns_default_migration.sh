#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM

policy_functions="$test_root/policy-functions.sh"
awk '/^query_status\(\) \{/ { exit } { sub(/\r$/, ""); print }' \
    openwrt/podkop-dns-optimizer > "$policy_functions"
. "$policy_functions"

NORMAL_SELECTION=""
BOOTSTRAP_SELECTION=""
uci() {
    [ "${1:-}" != "-q" ] || shift
    [ "${1:-}" = "get" ] || return 1
    case "${2:-}" in
        podkop.settings.dns_optimizer_candidates)
            [ -n "$NORMAL_SELECTION" ] || return 1
            printf '%s\n' "$NORMAL_SELECTION"
            ;;
        podkop.settings.dns_optimizer_bootstrap_candidates)
            [ -n "$BOOTSTRAP_SELECTION" ] || return 1
            printf '%s\n' "$BOOTSTRAP_SELECTION"
            ;;
        podkop.settings.dns_optimizer_include_current|podkop.settings.dns_optimizer_include_wan)
            printf '%s\n' 0
            ;;
        podkop.settings.dns_optimizer_custom_udp|podkop.settings.dns_optimizer_custom_doh|podkop.settings.dns_optimizer_custom_dot)
            return 1
            ;;
        *) return 1 ;;
    esac
}

candidate_ids() {
    awk -F '|' 'NF { if (output != "") output = output " "; output = output $1 } END { print output }' "$1"
}

assert_candidates() {
    protocol="$1"
    expected="$2"
    output="$test_root/main-$protocol"
    write_main_candidates "$protocol" "$output"
    actual="$(candidate_ids "$output")"
    [ "$actual" = "$expected" ] ||
        fail_test "$protocol default candidates: expected '$expected', got '$actual'"
}

assert_candidates udp 'cloudflare google controld_unfiltered'
assert_candidates doh 'cloudflare google controld_unfiltered'
assert_candidates dot 'cloudflare google controld_unfiltered'

bootstrap_output="$test_root/bootstrap"
write_bootstrap_candidates "$bootstrap_output"
bootstrap_ids="$(candidate_ids "$bootstrap_output")"
[ "$bootstrap_ids" = 'cloudflare_1 cloudflare_2 google_1 google_2 yandex_1 yandex_2 controld_unfiltered' ] ||
    fail_test "bootstrap default candidates: got '$bootstrap_ids'"

NORMAL_SELECTION='adguard_unfiltered mullvad'
manual_output="$test_root/manual-main"
write_main_candidates doh "$manual_output"
[ "$(candidate_ids "$manual_output")" = 'adguard_unfiltered mullvad' ] ||
    fail_test 'AdGuard Unfiltered and Mullvad must remain manually selectable as normal candidates'

BOOTSTRAP_SELECTION='adguard_unfiltered'
manual_bootstrap_output="$test_root/manual-bootstrap"
write_bootstrap_candidates "$manual_bootstrap_output"
[ "$(candidate_ids "$manual_bootstrap_output")" = 'adguard_unfiltered' ] ||
    fail_test 'AdGuard Unfiltered must remain manually selectable as bootstrap DNS'

grep -q '^adguard_unfiltered|AdGuard Unfiltered|' openwrt/podkop-dns-optimizer ||
    fail_test 'backend normal/bootstrap catalogs lost AdGuard Unfiltered'
grep -q '^mullvad|Mullvad|' openwrt/podkop-dns-optimizer ||
    fail_test 'backend normal catalog lost Mullvad'

grep -q '^dns_optimizer_candidate_set_matches() {' i ||
    fail_test 'installer lacks exact historical DNS candidate set matching'
grep -q '^migrate_dns_optimizer_candidate_defaults() {' i ||
    fail_test 'installer lacks one-time stock DNS candidate migration'
grep -q '^migrate_dns_optimizer_candidate_defaults || migration_status=$?$' i ||
    fail_test 'installer defines but does not run stock DNS candidate migration'
if sed -n '/^restore_runtime() {/,/^}/p; /^abort_with_restore() {/,/^}/p' i |
    grep -Eq 'uci (set|commit|revert)'; then
    fail_test 'installer rollback path mutates pending UCI state'
fi

migration_functions="$test_root/migration-functions.sh"
sed -n \
    -e '/^dns_optimizer_candidate_set_matches() {/,/^}/p' \
    -e '/^migrate_dns_optimizer_candidate_defaults() {/,/^}/p' \
    i > "$migration_functions"
. "$migration_functions"

MOCK_NORMAL=""
MOCK_BOOTSTRAP=""
MOCK_COMMIT_COUNT=0
MOCK_REVERT_COUNT=0
MOCK_SET_COUNT=0
MOCK_STAGED_CHANGES=""
MOCK_FAIL_SET_AT=0
MOCK_FAIL_COMMIT=0
MOCK_INITIAL_NORMAL=""
MOCK_INITIAL_BOOTSTRAP=""
log() { :; }
uci() {
    [ "${1:-}" != "-q" ] || shift
    case "${1:-}" in
        changes)
            [ "${2:-}" = podkop ] || return 1
            [ -n "$MOCK_STAGED_CHANGES" ] || return 0
            printf '%s\n' "$MOCK_STAGED_CHANGES"
            ;;
        get)
            case "${2:-}" in
                podkop.settings.dns_optimizer_candidates)
                    [ -n "$MOCK_NORMAL" ] || return 1
                    printf '%s\n' "$MOCK_NORMAL"
                    ;;
                podkop.settings.dns_optimizer_bootstrap_candidates)
                    [ -n "$MOCK_BOOTSTRAP" ] || return 1
                    printf '%s\n' "$MOCK_BOOTSTRAP"
                    ;;
                *) return 1 ;;
            esac
            ;;
        set)
            MOCK_SET_COUNT=$((MOCK_SET_COUNT + 1))
            if [ "$MOCK_FAIL_SET_AT" -eq "$MOCK_SET_COUNT" ]; then
                return 1
            fi
            assignment="${2:-}"
            case "$assignment" in
                podkop.settings.dns_optimizer_candidates=*)
                    MOCK_NORMAL="${assignment#*=}"
                    ;;
                podkop.settings.dns_optimizer_bootstrap_candidates=*)
                    MOCK_BOOTSTRAP="${assignment#*=}"
                    ;;
                *) return 1 ;;
            esac
            ;;
        commit)
            [ "${2:-}" = podkop ] || return 1
            MOCK_COMMIT_COUNT=$((MOCK_COMMIT_COUNT + 1))
            [ "$MOCK_FAIL_COMMIT" -ne 1 ] || return 1
            ;;
        revert)
            [ "${2:-}" = podkop ] || return 1
            MOCK_REVERT_COUNT=$((MOCK_REVERT_COUNT + 1))
            MOCK_NORMAL="$MOCK_INITIAL_NORMAL"
            MOCK_BOOTSTRAP="$MOCK_INITIAL_BOOTSTRAP"
            ;;
        *) return 1 ;;
    esac
}

run_migration_case() {
    name="$1"
    initial_normal="$2"
    initial_bootstrap="$3"
    expected_normal="$4"
    expected_bootstrap="$5"
    expected_commits="$6"

    MOCK_NORMAL="$initial_normal"
    MOCK_BOOTSTRAP="$initial_bootstrap"
    MOCK_INITIAL_NORMAL="$initial_normal"
    MOCK_INITIAL_BOOTSTRAP="$initial_bootstrap"
    MOCK_COMMIT_COUNT=0
    MOCK_REVERT_COUNT=0
    MOCK_SET_COUNT=0
    MOCK_STAGED_CHANGES=""
    MOCK_FAIL_SET_AT=0
    MOCK_FAIL_COMMIT=0
    migrate_dns_optimizer_candidate_defaults ||
        fail_test "$name: migration returned failure"
    [ "$MOCK_NORMAL" = "$expected_normal" ] ||
        fail_test "$name: normal selection changed to '$MOCK_NORMAL'"
    [ "$MOCK_BOOTSTRAP" = "$expected_bootstrap" ] ||
        fail_test "$name: bootstrap selection changed to '$MOCK_BOOTSTRAP'"
    [ "$MOCK_COMMIT_COUNT" -eq "$expected_commits" ] ||
        fail_test "$name: expected $expected_commits commit(s), got $MOCK_COMMIT_COUNT"
    [ "$MOCK_REVERT_COUNT" -eq 0 ] ||
        fail_test "$name: successful migration unexpectedly reverted UCI"
}

old_v1_normal='cloudflare google yandex adguard_unfiltered controld_unfiltered mullvad'
old_v2_normal='cloudflare google adguard_unfiltered controld_unfiltered mullvad'
old_bootstrap='cloudflare_1 cloudflare_2 google_1 google_2 yandex_1 yandex_2 adguard_unfiltered controld_unfiltered'
new_normal='cloudflare google controld_unfiltered'
new_bootstrap='cloudflare_1 cloudflare_2 google_1 google_2 yandex_1 yandex_2 controld_unfiltered'

run_migration_case \
    'v1 stock defaults' "$old_v1_normal" "$old_bootstrap" \
    "$new_normal" "$new_bootstrap" 1
run_migration_case \
    'v2 stock defaults in different order' \
    'mullvad controld_unfiltered google adguard_unfiltered cloudflare' \
    'controld_unfiltered yandex_2 google_2 cloudflare_2 adguard_unfiltered yandex_1 google_1 cloudflare_1' \
    "$new_normal" "$new_bootstrap" 1
run_migration_case \
    'custom selections' \
    'cloudflare google adguard_unfiltered' \
    'cloudflare_1 google_1 adguard_unfiltered' \
    'cloudflare google adguard_unfiltered' \
    'cloudflare_1 google_1 adguard_unfiltered' 0
run_migration_case \
    'manual-only selections' \
    'adguard_unfiltered mullvad' 'adguard_unfiltered' \
    'adguard_unfiltered mullvad' 'adguard_unfiltered' 0
run_migration_case 'unset selections' '' '' '' '' 0

MOCK_NORMAL="$old_v2_normal"
MOCK_BOOTSTRAP="$old_bootstrap"
MOCK_INITIAL_NORMAL="$MOCK_NORMAL"
MOCK_INITIAL_BOOTSTRAP="$MOCK_BOOTSTRAP"
MOCK_COMMIT_COUNT=0
MOCK_REVERT_COUNT=0
MOCK_SET_COUNT=0
MOCK_STAGED_CHANGES="podkop.settings.some_user_option='pending'"
MOCK_FAIL_SET_AT=0
MOCK_FAIL_COMMIT=0
pending_status=0
migrate_dns_optimizer_candidate_defaults || pending_status=$?
if [ "$pending_status" -eq 0 ]; then
    fail_test 'migration accepted pre-existing staged UCI changes'
fi
[ "$pending_status" -eq 2 ] ||
    fail_test "pending UCI guard returned $pending_status instead of the distinct status 2"
[ "$MOCK_NORMAL" = "$old_v2_normal" ] && [ "$MOCK_BOOTSTRAP" = "$old_bootstrap" ] ||
    fail_test 'pending UCI guard changed DNS selections'
[ "$MOCK_SET_COUNT" -eq 0 ] && [ "$MOCK_COMMIT_COUNT" -eq 0 ] && [ "$MOCK_REVERT_COUNT" -eq 0 ] ||
    fail_test 'pending UCI guard invoked set, commit, or revert'

MOCK_NORMAL="$old_v2_normal"
MOCK_BOOTSTRAP="$old_bootstrap"
MOCK_INITIAL_NORMAL="$MOCK_NORMAL"
MOCK_INITIAL_BOOTSTRAP="$MOCK_BOOTSTRAP"
MOCK_COMMIT_COUNT=0
MOCK_REVERT_COUNT=0
MOCK_SET_COUNT=0
MOCK_STAGED_CHANGES=""
MOCK_FAIL_SET_AT=2
MOCK_FAIL_COMMIT=0
if migrate_dns_optimizer_candidate_defaults; then
    fail_test 'migration reported success after the second UCI set failed'
fi
[ "$MOCK_NORMAL" = "$old_v2_normal" ] && [ "$MOCK_BOOTSTRAP" = "$old_bootstrap" ] ||
    fail_test 'set failure did not restore the original DNS selections'
[ "$MOCK_SET_COUNT" -eq 2 ] && [ "$MOCK_COMMIT_COUNT" -eq 0 ] && [ "$MOCK_REVERT_COUNT" -eq 1 ] ||
    fail_test 'set failure did not perform exactly one package revert without commit'

MOCK_NORMAL="$old_v2_normal"
MOCK_BOOTSTRAP="$old_bootstrap"
MOCK_INITIAL_NORMAL="$MOCK_NORMAL"
MOCK_INITIAL_BOOTSTRAP="$MOCK_BOOTSTRAP"
MOCK_COMMIT_COUNT=0
MOCK_REVERT_COUNT=0
MOCK_SET_COUNT=0
MOCK_STAGED_CHANGES=""
MOCK_FAIL_SET_AT=0
MOCK_FAIL_COMMIT=1
if migrate_dns_optimizer_candidate_defaults; then
    fail_test 'migration reported success after UCI commit failed'
fi
[ "$MOCK_NORMAL" = "$old_v2_normal" ] && [ "$MOCK_BOOTSTRAP" = "$old_bootstrap" ] ||
    fail_test 'commit failure did not restore the original DNS selections'
[ "$MOCK_SET_COUNT" -eq 2 ] && [ "$MOCK_COMMIT_COUNT" -eq 1 ] && [ "$MOCK_REVERT_COUNT" -eq 1 ] ||
    fail_test 'commit failure did not perform exactly one package revert'

grep -q '^VERSION="20260813-dns-optimizer-v15"$' openwrt/podkop-dns-optimizer ||
    fail_test 'DNS optimizer version was not bumped to v15'
for installer in i openwrt/install.sh; do
    grep -q '^INSTALL_MARKER="PODKOP_SUBSCRIPTIONS_PATCH_VERSION=20260813-reliability-responsive-v3"$' "$installer" ||
        fail_test "$installer patch marker was not bumped to v3"
    grep -q '^DNS_OPTIMIZER_VERSION="20260813-dns-optimizer-v15"$' "$installer" ||
        fail_test "$installer DNS optimizer version was not bumped to v15"
    grep -q '^LUCI_MODULE_NAMESPACE="podkop_patch_20260813_reliability_responsive_v3"$' "$installer" ||
        fail_test "$installer LuCI namespace was not bumped to v3"
done

[ "$(jq -r '.patchVersion' openwrt/update-manifest.json)" = '20260813-reliability-responsive-v3' ] ||
    fail_test 'update manifest patch version was not bumped to v3'

cmp -s i openwrt/install.sh ||
    fail_test 'unified installer copies differ'

printf '%s\n' 'PASS: DNS defaults and exact stock-config migration are safe'
