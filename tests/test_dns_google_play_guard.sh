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

optimizer_functions="$test_root/optimizer-functions.sh"
awk '/^case "\$\{1:-\}" in$/ { exit } { sub(/\r$/, ""); print }' \
    openwrt/podkop-dns-optimizer > "$optimizer_functions"
. "$optimizer_functions"

# Google Play compatibility must cover both its control plane and download path.
write_selected_community_services() {
    printf '%s\n' google_play > "$1"
}

probes="$test_root/probes"
selected="$test_root/selected"
write_compatibility_domains "$probes" "$selected"
for probe in \
    'base|google_play|play.googleapis.com' \
    'base|google_play|play-fe.googleapis.com' \
    'base|google_play|prod-lt-playstoregatewayadapter-pa.googleapis.com' \
    'base|google_play|beacons.gvt2.com' \
    'base|google_downloads|dl.google.com' \
    'base|google_downloads|redirector.gvt1.com' \
    'base|chatgpt|chatgpt.com' \
    'base|chatgpt|chat.openai.com' \
    'base|chatgpt|api.openai.com' \
    'base|chatgpt|auth.openai.com' \
    'base|chatgpt|cdn.oaistatic.com' \
    'base|chatgpt|files.oaiusercontent.com' \
    'community|google_play|play.googleapis.com' \
    'community|google_play|play-fe.googleapis.com' \
    'community|google_play|prod-lt-playstoregatewayadapter-pa.googleapis.com' \
    'community|google_play|beacons.gvt2.com'; do
    grep -Fxq "$probe" "$probes" ||
        record_failure "missing critical Google Play/ChatGPT DNS probe: $probe"
done

# Candidate resolvers must not pass by returning a sinkhole, private, or bogon A record.
MOCK_DNS_ANSWER=""
dig() {
    printf '%s\n' ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1'
    [ -z "$MOCK_DNS_ANSWER" ] ||
        printf 'example.com. 60 IN A %s\n' "$MOCK_DNS_ANSWER"
    printf '%s\n' ';; Query time: 3 msec'
}
run_with_timeout() {
    shift
    "$@"
}

assert_dns_rejected() {
    label="$1"
    endpoint="$2"
    MOCK_DNS_ANSWER="$3"
    export MOCK_DNS_ANSWER
    if run_dns_query udp "$endpoint" "" "" example.com NOERROR > /dev/null 2>&1; then
        record_failure "$label A answer was accepted: $MOCK_DNS_ANSWER"
    fi
}

for rejected in \
    'unspecified|0.0.0.0' \
    'private-10|10.0.0.1' \
    'shared-address|100.64.0.1' \
    'loopback|127.0.0.1' \
    'link-local|169.254.1.1' \
    'private-172|172.16.0.1' \
    'private-192|192.168.1.1' \
    'documentation-192|192.0.2.1' \
    'benchmark|198.18.0.1' \
    'documentation-198|198.51.100.1' \
    'documentation-203|203.0.113.1' \
    'multicast|224.0.0.1'; do
    old_ifs="$IFS"
    IFS='|'
    set -- $rejected
    IFS="$old_ifs"
    assert_dns_rejected "$1" 1.1.1.1 "$2"
done

MOCK_DNS_ANSWER=142.250.185.174
export MOCK_DNS_ANSWER
if ! run_dns_query udp 1.1.1.1 "" "" example.com NOERROR > /dev/null 2>&1; then
    record_failure 'a normal public DNS A answer was rejected'
fi

# The local Podkop resolver intentionally returns RFC 2544 FakeIP addresses.
MOCK_DNS_ANSWER=198.18.0.7
export MOCK_DNS_ANSWER
for local_resolver in 127.0.0.42 127.0.0.1; do
    if ! run_dns_query udp "$local_resolver" "" "" play.googleapis.com NOERROR > /dev/null 2>&1; then
        record_failure "the local Podkop FakeIP answer was rejected via $local_resolver"
    fi
done

# A configured DNS pair is never healthy when either mandatory service lookup fails.
read_configured_pair() {
    printf '%s\n' 'udp|1.1.1.1|8.8.8.8'
}
PAIR_FAILED_DOMAIN=play.googleapis.com
run_dns_query() {
    [ "$5" != "$PAIR_FAILED_DOMAIN" ] || return 1
    printf '%s\n' 5
}

pair_output="$(probe_configured_pair primary)"
pair_status=$?
if [ "$pair_status" -eq 0 ]; then
    record_failure 'configured pair passed 2/3 even though play.googleapis.com failed'
fi
if ! printf '%s\n' "$pair_output" | jq -e '.success == false' > /dev/null 2>&1; then
    record_failure 'configured pair did not report Google Play DNS failure as structured JSON'
fi

PAIR_FAILED_DOMAIN=chatgpt.com
pair_output="$(probe_configured_pair primary)"
pair_status=$?
if [ "$pair_status" -eq 0 ]; then
    record_failure 'configured pair passed even though chatgpt.com failed'
fi
if ! printf '%s\n' "$pair_output" | jq -e \
    '.success == false and .error == "chatgpt_dns_unavailable"' > /dev/null 2>&1; then
    record_failure 'configured pair did not report mandatory ChatGPT DNS failure'
fi

PAIR_FAILED_DOMAIN=github.com
pair_output="$(probe_configured_pair primary)"
pair_status=$?
if [ "$pair_status" -ne 0 ] ||
    [ "$(printf '%s\n' "$pair_output" | jq -r '.success // false')" != true ]; then
    record_failure 'configured pair rejected healthy mandatory Play/ChatGPT lookups plus one healthy general lookup'
fi

# The post-apply guard must make two small HTTPS transfers through normal system DNS.
curl_log="$test_root/curl.log"
CANARY_MODE=success
curl() {
    printf '%s\n' "$*" >> "$curl_log"
    output=""
    url=""
    expect_output=0
    for argument in "$@"; do
        if [ "$expect_output" -eq 1 ]; then
            output="$argument"
            expect_output=0
            continue
        fi
        case "$argument" in
            -o|--output) expect_output=1 ;;
            https://*) url="$argument" ;;
        esac
    done
    case "$url" in
        *dl.google.com*) key=dl ;;
        *redirector.gvt1.com*) key=gvt1 ;;
        https://chatgpt.com/.well-known/http-message-signatures-directory) key=chatgpt ;;
        https://api.openai.com/v1/models) key=openai_api ;;
        *) key=unknown ;;
    esac
    attempt_file="$test_root/attempt-$key"
    attempt=0
    [ ! -s "$attempt_file" ] || attempt="$(cat "$attempt_file")"
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" > "$attempt_file"

    case "$CANARY_MODE|$key|$attempt" in
        retry_once\|dl\|1) return 28 ;;
        retry_chatgpt_once\|chatgpt\|1) return 28 ;;
        fail_gvt1\|gvt1\|*) return 28 ;;
        fail_chatgpt\|chatgpt\|*) return 28 ;;
        fail_openai_api\|openai_api\|*) return 28 ;;
    esac
    [ -n "$output" ] || return 2
    case "$CANARY_MODE" in
        empty) : ;;
        *)
            printf '%s\n' \
                'required-service-transport-canary-payload-that-is-long-enough-to-prove-a-real-transfer' \
                > "$output"
            ;;
    esac
    case "$key" in
        openai_api) http_status=401 ;;
        *) http_status=200 ;;
    esac
    case "$CANARY_MODE|$key" in
        chatgpt_206\|chatgpt) http_status=206 ;;
        wrong_chatgpt_status\|chatgpt) http_status=403 ;;
        wrong_openai_api_status\|openai_api) http_status=200 ;;
    esac
    printf '%s' "$http_status"
}

reset_canary() {
    CANARY_MODE="$1"
    export CANARY_MODE
    : > "$curl_log"
    rm -f "$test_root"/attempt-* 2> /dev/null || true
}

if ! command -v validate_google_play_transport > /dev/null 2>&1; then
    record_failure 'post-apply Google Play HTTPS transport guard is missing'
else
    reset_canary success
    if ! validate_google_play_transport; then
        record_failure 'Google Play transport guard rejected two successful canaries'
    fi
    grep -q 'https://dl\.google\.com/' "$curl_log" ||
        record_failure 'transport guard did not test dl.google.com'
    grep -q 'https://redirector\.gvt1\.com/' "$curl_log" ||
        record_failure 'transport guard did not test redirector.gvt1.com'
    if grep -Eq -- '--resolve|--doh-url|https://[0-9]+\.' "$curl_log"; then
        record_failure 'transport guard bypassed normal system DNS/FakeIP routing'
    fi
    grep -q -- '--connect-timeout' "$curl_log" ||
        record_failure 'transport guard lacks a connection timeout'
    grep -q -- '--max-time' "$curl_log" ||
        record_failure 'transport guard lacks a total transfer timeout'
    grep -q -- '--range' "$curl_log" ||
        record_failure 'transport guard does not bound the downloaded payload'

    reset_canary retry_once
    if ! validate_google_play_transport; then
        record_failure 'transport guard did not recover from one transient canary failure'
    fi
    [ "$(cat "$test_root/attempt-dl" 2> /dev/null || echo 0)" -eq 2 ] ||
        record_failure 'transport guard did not retry the transient endpoint exactly once'

    reset_canary fail_gvt1
    if validate_google_play_transport; then
        record_failure 'transport guard accepted a persistent GVT1 download failure'
    fi
    [ "$(cat "$test_root/attempt-gvt1" 2> /dev/null || echo 0)" -eq 2 ] ||
        record_failure 'transport guard did not limit a failed endpoint to two attempts'

    reset_canary empty
    if validate_google_play_transport; then
        record_failure 'transport guard accepted empty successful HTTP responses'
    fi
fi

if ! command -v validate_chatgpt_transport > /dev/null 2>&1; then
    record_failure 'post-apply ChatGPT HTTPS transport guard is missing'
else
    reset_canary success
    if ! validate_chatgpt_transport; then
        record_failure 'ChatGPT transport guard rejected the expected 200/401 canaries'
    fi
    grep -q 'https://chatgpt\.com/\.well-known/http-message-signatures-directory' "$curl_log" ||
        record_failure 'transport guard did not test the official ChatGPT well-known endpoint'
    grep -q 'https://api\.openai\.com/v1/models' "$curl_log" ||
        record_failure 'transport guard did not test the unauthenticated OpenAI API response'
    if grep -Eq -- '--resolve|--doh-url|https://[0-9]+\.' "$curl_log"; then
        record_failure 'ChatGPT transport guard bypassed normal system DNS/FakeIP routing'
    fi
    if grep -Eiq -- 'authorization|bearer' "$curl_log"; then
        record_failure 'OpenAI API canary unexpectedly sent authentication material'
    fi
    grep -q -- '--connect-timeout' "$curl_log" ||
        record_failure 'ChatGPT transport guard lacks a connection timeout'
    grep -q -- '--max-time' "$curl_log" ||
        record_failure 'ChatGPT transport guard lacks a total transfer timeout'
    grep -q -- '--range' "$curl_log" ||
        record_failure 'ChatGPT transport guard does not bound the downloaded payload'

    reset_canary retry_chatgpt_once
    if ! validate_chatgpt_transport; then
        record_failure 'ChatGPT transport guard did not recover from one transient well-known endpoint failure'
    fi
    [ "$(cat "$test_root/attempt-chatgpt" 2> /dev/null || echo 0)" -eq 2 ] ||
        record_failure 'ChatGPT well-known canary was not retried exactly once'

    reset_canary fail_openai_api
    if ! validate_chatgpt_transport; then
        record_failure 'advisory OpenAI API timeout incorrectly failed the mandatory ChatGPT guard'
    fi
    [ "$(cat "$test_root/attempt-openai_api" 2> /dev/null || echo 0)" -eq 2 ] ||
        record_failure 'advisory OpenAI API canary was not attempted twice before being ignored'

    reset_canary fail_chatgpt
    if validate_chatgpt_transport; then
        record_failure 'ChatGPT transport guard accepted a persistent mandatory well-known failure'
    fi
    [ "$(cat "$test_root/attempt-chatgpt" 2> /dev/null || echo 0)" -eq 2 ] ||
        record_failure 'mandatory ChatGPT well-known canary did not stop after two attempts'

    reset_canary chatgpt_206
    if ! validate_chatgpt_transport; then
        record_failure 'ChatGPT transport guard rejected valid HTTP 206 from the mandatory well-known endpoint'
    fi

    reset_canary wrong_chatgpt_status
    if validate_chatgpt_transport; then
        record_failure 'ChatGPT transport guard accepted well-known HTTP 403 instead of 200'
    fi

    reset_canary wrong_openai_api_status
    if ! validate_chatgpt_transport; then
        record_failure 'advisory OpenAI API HTTP status incorrectly failed the mandatory ChatGPT guard'
    fi

    reset_canary empty
    if validate_chatgpt_transport; then
        record_failure 'ChatGPT transport guard accepted empty HTTP responses'
    fi
fi

apply_body="$(sed -n '/^run_apply() {/,/^}/p' openwrt/podkop-dns-optimizer)"
if ! printf '%s\n' "$apply_body" | grep -q 'validate_google_play_transport'; then
    record_failure 'apply does not invoke the Google Play transport guard before success'
fi
if ! printf '%s\n' "$apply_body" | grep -q 'validate_chatgpt_transport'; then
    record_failure 'apply does not invoke the ChatGPT transport guard before success'
fi

# Prove that a transport failure reaches the existing transactional rollback branch.
if command -v validate_google_play_transport > /dev/null 2>&1 &&
    command -v validate_chatgpt_transport > /dev/null 2>&1; then
    action_log="$test_root/apply-actions.log"
    cleanup_optimizer_mutation() { :; }
    podkop_mutation_lock_acquire() { return 0; }
    lookup_main_candidate() { printf '%s\n' 'cloudflare|Cloudflare|1.1.1.1|unfiltered'; }
    bootstrap_is_allowed() { return 0; }
    candidate_is_primary_eligible() { return 0; }
    is_ipv4() { return 0; }
    write_status() { :; }
    save_previous_dns() { return 0; }
    restart_podkop() { return 0; }
    validate_podkop_dns() { return 0; }
    restore_previous_dns() {
        printf '%s\n' restore_previous_dns >> "$action_log"
        return 0
    }
    write_apply_final() {
        printf '%s|%s\n' "$2" "$7" >> "$action_log"
    }
    uci() {
        [ "${1:-}" != -q ] || shift
        case "${1:-}" in
            get) printf '%s\n' 0 ;;
            set|commit) return 0 ;;
            *) return 1 ;;
        esac
    }

    reset_canary fail_openai_api
    : > "$action_log"
    set +u
    run_apply udp cloudflare 8.8.8.8 1.1.1.1
    apply_status=$?
    set -u
    trap 'rm -rf "$test_root"' EXIT INT TERM
    [ "$apply_status" -eq 0 ] ||
        record_failure 'advisory OpenAI API failure incorrectly rolled back DNS apply'
    if grep -Fxq restore_previous_dns "$action_log"; then
        record_failure 'advisory OpenAI API failure invoked rollback'
    fi
    grep -Fxq 'apply_complete|false' "$action_log" ||
        record_failure 'advisory OpenAI API failure did not retain the verified DNS apply'

    reset_canary fail_chatgpt
    : > "$action_log"
    set +u
    run_apply udp cloudflare 8.8.8.8 1.1.1.1
    apply_status=$?
    set -u
    trap 'rm -rf "$test_root"' EXIT INT TERM
    [ "$apply_status" -ne 0 ] ||
        record_failure 'apply succeeded despite a failed mandatory ChatGPT well-known canary'
    grep -Fxq restore_previous_dns "$action_log" ||
        record_failure 'transport failure did not restore the previous DNS configuration'
    grep -Fxq 'apply_failed_rolled_back|true' "$action_log" ||
        record_failure 'transport failure did not report the existing rolled-back apply state'
fi

if [ "$failures" -ne 0 ]; then
    printf 'FAIL: Google Play/ChatGPT DNS/transport guard has %s regression(s)\n' "$failures" >&2
    exit 1
fi

printf '%s\n' 'PASS: Google Play and ChatGPT failures cannot survive DNS auto-apply'
