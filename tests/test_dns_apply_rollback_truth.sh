#!/bin/sh
set -u

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

failures=0
record_failure() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM
export PODKOP_DNS_OPTIMIZER_PERSIST_DIR="$test_root/persist"
mkdir -p "$PODKOP_DNS_OPTIMIZER_PERSIST_DIR"

optimizer_functions="$test_root/optimizer-functions.sh"
awk '/^case "\$\{1:-\}" in$/ { exit } { sub(/\r$/, ""); print }' \
    openwrt/podkop-dns-optimizer > "$optimizer_functions"
. "$optimizer_functions"

uci_state="$test_root/uci-state"
uci_commit_count="$test_root/uci-commit-count"
MOCK_FAIL_SET_KEY=""
MOCK_FAIL_DELETE_KEY=""
MOCK_FAIL_COMMIT=0
MOCK_MISMATCH_GET_KEY=""

state_put() {
    key="$1"
    value="$2"
    tmp="$uci_state.tmp"
    awk -F '=' -v key="$key" '$1 != key { print }' "$uci_state" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$uci_state"
}

state_delete() {
    key="$1"
    tmp="$uci_state.tmp"
    if ! awk -F '=' -v key="$key" '$1 == key { found = 1 } END { exit !found }' "$uci_state"; then
        return 1
    fi
    awk -F '=' -v key="$key" '$1 != key { print }' "$uci_state" > "$tmp"
    mv "$tmp" "$uci_state"
}

state_get() {
    key="$1"
    awk -F '=' -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found = 1; exit } END { exit !found }' "$uci_state"
}

uci() {
    [ "${1:-}" != -q ] || shift
    command="${1:-}"
    shift || true
    case "$command" in
        get)
            key="${1:-}"
            if [ "$key" = "$MOCK_MISMATCH_GET_KEY" ]; then
                printf '%s\n' '__verification_mismatch__'
                return 0
            fi
            state_get "$key"
            ;;
        set)
            assignment="${1:-}"
            key="${assignment%%=*}"
            value="${assignment#*=}"
            [ "$key" != "$MOCK_FAIL_SET_KEY" ] || return 1
            state_put "$key" "$value"
            ;;
        delete)
            key="${1:-}"
            [ "$key" != "$MOCK_FAIL_DELETE_KEY" ] || return 1
            state_delete "$key"
            ;;
        commit)
            count=0
            [ ! -s "$uci_commit_count" ] || count="$(cat "$uci_commit_count")"
            count=$((count + 1))
            printf '%s\n' "$count" > "$uci_commit_count"
            [ "$MOCK_FAIL_COMMIT" -ne 1 ]
            ;;
        *) return 1 ;;
    esac
}

write_previous_dns() {
    optional_mode="${1:-present}"
    if [ "$optional_mode" = absent ]; then
        failover_enabled=""
        active_slot=""
        secondary_type=""
        secondary_server=""
        secondary_bootstrap=""
    else
        failover_enabled=1
        active_slot=secondary
        secondary_type=doh
        secondary_server=dns.google/dns-query
        secondary_bootstrap=8.8.8.8
    fi
    jq -cn \
        --arg dnsType udp --arg dnsServer 9.9.9.9 --arg bootstrapDnsServer 1.1.1.1 \
        --arg failoverEnabled "$failover_enabled" --arg activeSlot "$active_slot" \
        --arg secondaryDnsType "$secondary_type" --arg secondaryDnsServer "$secondary_server" \
        --arg secondaryBootstrapDnsServer "$secondary_bootstrap" \
        '{dnsType:$dnsType,dnsServer:$dnsServer,bootstrapDnsServer:$bootstrapDnsServer,failoverEnabled:$failoverEnabled,activeSlot:$activeSlot,secondaryDnsType:$secondaryDnsType,secondaryDnsServer:$secondaryDnsServer,secondaryBootstrapDnsServer:$secondaryBootstrapDnsServer}' \
        > "$PREVIOUS_FILE"
}

reset_restore_case() {
    optional_mode="${1:-present}"
    cat > "$uci_state" <<'EOF'
podkop.settings.dns_type=dot
podkop.settings.dns_server=1.0.0.1
podkop.settings.bootstrap_dns_server=8.8.4.4
podkop.settings.dns_failover_enabled=0
podkop.settings.dns_failover_active_slot=primary
podkop.settings.secondary_dns_type=udp
podkop.settings.secondary_dns_server=76.76.2.0
podkop.settings.secondary_bootstrap_dns_server=1.0.0.1
EOF
    : > "$uci_commit_count"
    MOCK_FAIL_SET_KEY=""
    MOCK_FAIL_DELETE_KEY=""
    MOCK_FAIL_COMMIT=0
    MOCK_MISMATCH_GET_KEY=""
    write_previous_dns "$optional_mode"
}

assert_restore_failure() {
    description="$1"
    if restore_previous_dns; then
        record_failure "$description was reported as a successful restore"
    fi
}

reset_restore_case
MOCK_FAIL_SET_KEY=podkop.settings.dns_server
assert_restore_failure 'required UCI set failure'

reset_restore_case
MOCK_FAIL_SET_KEY=podkop.settings.secondary_dns_server
assert_restore_failure 'optional UCI set failure'

reset_restore_case
MOCK_FAIL_COMMIT=1
assert_restore_failure 'UCI commit failure'

reset_restore_case
MOCK_MISMATCH_GET_KEY=podkop.settings.dns_server
assert_restore_failure 'post-commit required-value verification mismatch'

reset_restore_case absent
MOCK_FAIL_DELETE_KEY=podkop.settings.secondary_dns_server
assert_restore_failure 'post-commit optional-value deletion mismatch'

reset_restore_case
if ! restore_previous_dns; then
    record_failure 'valid previous DNS state failed to restore'
fi
for expected in \
    'podkop.settings.dns_type=udp' \
    'podkop.settings.dns_server=9.9.9.9' \
    'podkop.settings.bootstrap_dns_server=1.1.1.1' \
    'podkop.settings.dns_failover_enabled=1' \
    'podkop.settings.dns_failover_active_slot=secondary' \
    'podkop.settings.secondary_dns_type=doh' \
    'podkop.settings.secondary_dns_server=dns.google/dns-query' \
    'podkop.settings.secondary_bootstrap_dns_server=8.8.8.8'; do
    grep -Fxq "$expected" "$uci_state" ||
        record_failure "restored UCI state is missing $expected"
done

apply_action_log="$test_root/apply-actions"
ROLLBACK_SCENARIO=success
RESTART_CALLS=0
VALIDATE_CALLS=0

cleanup_optimizer_mutation() { :; }
podkop_mutation_lock_acquire() { return 0; }
lookup_main_candidate() { printf '%s\n' 'cloudflare|Cloudflare|1.1.1.1|unfiltered'; }
bootstrap_is_allowed() { return 0; }
candidate_is_primary_eligible() { return 0; }
is_ipv4() { return 0; }
write_status() { :; }
save_previous_dns() { return 0; }
validate_google_play_transport() { return 0; }
validate_chatgpt_transport() { return 0; }
restore_previous_dns() {
    printf '%s\n' restore_previous_dns >> "$apply_action_log"
    [ "$ROLLBACK_SCENARIO" != restore_failure ]
}
restart_podkop() {
    RESTART_CALLS=$((RESTART_CALLS + 1))
    printf 'restart_podkop:%s\n' "$RESTART_CALLS" >> "$apply_action_log"
    if [ "$ROLLBACK_SCENARIO" = restart_failure ] && [ "$RESTART_CALLS" -eq 2 ]; then
        return 1
    fi
    return 0
}
validate_podkop_dns() {
    VALIDATE_CALLS=$((VALIDATE_CALLS + 1))
    printf 'validate_podkop_dns:%s\n' "$VALIDATE_CALLS" >> "$apply_action_log"
    [ "$VALIDATE_CALLS" -ne 1 ] || return 1
    [ "$ROLLBACK_SCENARIO" != restored_validation_failure ]
}
write_apply_final() {
    printf 'final:%s|%s\n' "$2" "$7" >> "$apply_action_log"
}

run_apply_rollback_case() {
    ROLLBACK_SCENARIO="$1"
    expected_final="$2"
    expected_restarts="$3"
    expected_validations="$4"
    RESTART_CALLS=0
    VALIDATE_CALLS=0
    : > "$apply_action_log"
    MOCK_FAIL_SET_KEY=""
    MOCK_FAIL_DELETE_KEY=""
    MOCK_FAIL_COMMIT=0
    MOCK_MISMATCH_GET_KEY=""
    reset_restore_case

    set +u
    run_apply udp cloudflare 8.8.8.8 1.1.1.1
    status=$?
    set -u
    trap 'rm -rf "$test_root"' EXIT INT TERM
    [ "$status" -ne 0 ] || record_failure "$ROLLBACK_SCENARIO rollback scenario unexpectedly returned success"
    grep -Fxq "final:$expected_final" "$apply_action_log" ||
        record_failure "$ROLLBACK_SCENARIO rollback scenario reported an untruthful final state"
    [ "$RESTART_CALLS" -eq "$expected_restarts" ] ||
        record_failure "$ROLLBACK_SCENARIO rollback scenario used $RESTART_CALLS restart(s), expected $expected_restarts"
    [ "$VALIDATE_CALLS" -eq "$expected_validations" ] ||
        record_failure "$ROLLBACK_SCENARIO rollback scenario used $VALIDATE_CALLS validation(s), expected $expected_validations"
}

run_apply_rollback_case success 'apply_failed_rolled_back|true' 2 2
run_apply_rollback_case restore_failure 'apply_failed_rollback_failed|false' 1 1
run_apply_rollback_case restart_failure 'apply_failed_rollback_failed|false' 2 1
run_apply_rollback_case restored_validation_failure 'apply_failed_rollback_failed|false' 2 2

apply_body="$(sed -n '/^run_apply() {/,/^}/p' openwrt/podkop-dns-optimizer)"
if printf '%s\n' "$apply_body" | grep -Eq 'restart_podkop[^|]*\|\|[[:space:]]*true'; then
    record_failure 'apply rollback masks a failed restorative Podkop restart with || true'
fi

if [ "$failures" -ne 0 ]; then
    printf 'FAIL: DNS rollback truth has %s regression(s)\n' "$failures" >&2
    exit 1
fi

printf '%s\n' 'PASS: DNS rollback success is reported only after verified restoration'
