#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo_root/openwrt/runtime-0.7.22/usr/bin/podkop"
test_root="$(mktemp -d)"
library="$test_root/library.sh"
failures=0

cleanup() {
	rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

record_failure() {
	printf 'FAIL: %s\n' "$1" >&2
	failures=$((failures + 1))
}

extract_function() {
	name="$1"
	sed -n "/^${name}() {$/,/^}$/p" "$runtime"
}

for function_name in \
	is_valid_vless_uuid \
	is_valid_proxy_port \
	get_subscription_proxy_skip_reason \
	normalize_subscription_proxy_link \
	subscription_response_requires_hwid \
	subscription_response_rejects_hwid \
	get_subscription_request_hwid \
	download_subscription_once \
	download_subscription_to_file; do
	if ! extract_function "$function_name" | grep -q .; then
		record_failure "runtime is missing $function_name"
	else
		extract_function "$function_name" >> "$library"
	fi
done

url_get_scheme() {
	printf '%s\n' vless
}
url_get_query_param() {
	case "$1:$2" in
	valid-tcp:type) printf '%s\n' tcp ;;
	*) printf '%s\n' '' ;;
	esac
}
url_get_userinfo() {
	case "$1" in
	fake-placeholder) printf '%s\n' not-a-valid-uuid ;;
	*) printf '%s\n' 01234567-89ab-4cde-8fab-0123456789ab ;;
	esac
}
url_get_host() {
	case "$1" in
	*provider-a.example*) printf '%s\n' provider-a.example ;;
	*provider-b.example*) printf '%s\n' provider-b.example ;;
	*) printf '%s\n' 203.0.113.10 ;;
	esac
}
url_get_port() {
	case "$1" in
	fake-placeholder) printf '%s\n' 1 ;;
	*) printf '%s\n' 443 ;;
	esac
}
is_shadowsocks_userinfo_format() {
	return 0
}
url_decode() {
	printf '%s\n' "$1"
}
log() {
	:
}

if [ -s "$library" ]; then
	# shellcheck disable=SC1090
	. "$library"
fi

if command -v get_subscription_proxy_skip_reason >/dev/null 2>&1; then
	fake_reason=''
	if fake_reason="$(get_subscription_proxy_skip_reason fake-placeholder)"; then
		[ "$fake_reason" = invalid_config ] ||
			record_failure "Atlanta placeholder was classified as '$fake_reason' instead of invalid_config"
	else
		record_failure 'Atlanta placeholder with an invalid VLESS UUID was accepted'
	fi

	if missing_reason="$(get_subscription_proxy_skip_reason valid-missing-type)"; then
		record_failure "valid VLESS without type was rejected as '$missing_reason'"
	fi
fi

if command -v normalize_subscription_proxy_link >/dev/null 2>&1; then
	normalized="$(normalize_subscription_proxy_link \
		'vless://01234567-89ab-4cde-8fab-0123456789ab@example.com:443?security=tls#Valid')"
	case "$normalized" in
	*'?security=tls&type=tcp#Valid') : ;;
	*) record_failure 'valid VLESS without type was not normalized to explicit TCP' ;;
	esac
fi

filter_body="$(sed -n '/^filter_working_subscription_proxy_links() {$/,/^}$/p' "$runtime")"
printf '%s\n' "$filter_body" | grep -q 'normalize_subscription_proxy_link' ||
	record_failure 'subscription filtering does not normalize links before sing-box validation'

installer="$repo_root/i"
sed -n '/^has_latest_subscription_backend() {$/,/^}$/p' "$installer" |
	grep -q 'subscription_hwid_placeholder_guard begin' ||
	record_failure 'installer no-op predicate does not require the HWID/placeholder guard'
grep -q 'hwid_runtime_source=.*podkop.runtime-0.7.22' "$installer" ||
	record_failure 'installer does not deliver the guarded runtime to Podkop 0.7.22'
grep -q 'hwid_runtime_source=.*podkop.runtime-0.7.20' "$installer" ||
	record_failure 'installer does not deliver the guarded runtime to older supported Podkop versions'
cmp -s "$installer" "$repo_root/openwrt/install.sh" ||
	record_failure 'root and OpenWrt installers differ after HWID guard integration'

if command -v get_subscription_request_hwid >/dev/null 2>&1; then
	PODKOP_SUBSCRIPTION_HWID_SEED_FILE="$test_root/hwid.seed"
	export PODKOP_SUBSCRIPTION_HWID_SEED_FILE
	hwid_a1="$(get_subscription_request_hwid 'https://provider-a.example/sub/one')"
	hwid_a2="$(get_subscription_request_hwid 'https://provider-a.example/sub/two')"
	hwid_b="$(get_subscription_request_hwid 'https://provider-b.example/sub/one')"
	printf '%s\n' "$hwid_a1" | grep -Eq '^[0-9a-f]{64}$' ||
		record_failure 'generated subscription HWID is not a 64-character lowercase digest'
	[ "$hwid_a1" = "$hwid_a2" ] ||
		record_failure 'subscription HWID is not stable for the same provider host'
	[ "$hwid_a1" != "$hwid_b" ] ||
		record_failure 'subscription HWID is reused across different provider hosts'
	case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*)
		printf '%s\n' 'SKIP: POSIX mode 600 must be verified on the OpenWrt canary (Windows filesystem)'
		;;
	*)
		[ "$(stat -c '%a' "$PODKOP_SUBSCRIPTION_HWID_SEED_FILE")" = 600 ] ||
			record_failure 'subscription HWID seed is not stored with mode 600'
		;;
	esac
	grep -q '/proc/sys/kernel/random/uuid' "$runtime" ||
		record_failure 'subscription HWID generation still depends on optional OpenWrt utilities'

	rm -f "$PODKOP_SUBSCRIPTION_HWID_SEED_FILE"
	concurrent_results="$test_root/concurrent-hwids"
	: > "$concurrent_results"
	for worker in 1 2 3 4 5 6 7 8; do
		(get_subscription_request_hwid 'https://provider-a.example/sub/concurrent' >> "$concurrent_results") &
	done
	wait
	[ "$(sort -u "$concurrent_results" | wc -l | tr -d ' ')" -eq 1 ] ||
		record_failure 'concurrent subscription refreshes generated more than one HWID'
fi

if command -v subscription_response_requires_hwid >/dev/null 2>&1; then
	printf 'HTTP/2 200\r\nX-Hwid-Not-Supported: true\r\n\r\n' > "$test_root/headers"
	subscription_response_requires_hwid "$test_root/headers" ||
		record_failure 'HWID-required response header was not detected case-insensitively'
	printf 'HTTP/2 200\r\nX-Hwid-Not-Supported: false\r\n\r\n' > "$test_root/headers"
	if subscription_response_requires_hwid "$test_root/headers"; then
		record_failure 'ordinary subscription response was misclassified as HWID-required'
	fi
fi

if command -v download_subscription_to_file >/dev/null 2>&1; then
	PODKOP_SUBSCRIPTION_HWID_SEED_FILE="$test_root/hwid.seed"
	request_count=0
	hwid_request_count=0
	download_subscription_once() {
		request_count=$((request_count + 1))
		request_url="$1"
		request_output="$2"
		request_headers="$4"
		request_hwid="$5"
		if [ -z "$request_hwid" ]; then
			printf '%s\n' fake-placeholder > "$request_output"
			printf 'HTTP/2 200\r\nX-Hwid-Not-Supported: true\r\n\r\n' > "$request_headers"
		else
			hwid_request_count=$((hwid_request_count + 1))
			printf '%s\n' real-subscription > "$request_output"
			printf 'HTTP/2 200\r\nX-Hwid-Active: true\r\n\r\n' > "$request_headers"
		fi
		return 0
	}

	if ! download_subscription_to_file \
		'https://provider-a.example/sub/token' "$test_root/body" '' 1 0; then
		record_failure 'HWID-aware subscription retry failed'
	elif [ "$(cat "$test_root/body")" != real-subscription ]; then
		record_failure 'HWID-required placeholder body was kept instead of the real retry response'
	fi
	[ "$request_count" -eq 2 ] ||
		record_failure "HWID-required subscription used $request_count requests instead of 2"
	[ "$hwid_request_count" -eq 1 ] ||
		record_failure 'HWID retry did not send exactly one non-empty device identifier'
fi

if [ "$failures" -ne 0 ]; then
	printf 'FAIL: subscription HWID/placeholder guard has %s regression(s)\n' "$failures" >&2
	exit 1
fi

printf '%s\n' 'PASS: HWID-bound subscription placeholders are safe and real configs can be fetched'
