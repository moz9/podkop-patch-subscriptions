#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
. "$repo/openwrt/podkop-subscription-sources.sh"
runtime="${PODKOP_TEST_RUNTIME:-$repo/openwrt/runtime-0.7.24/usr/bin/podkop}"
eval "$(sed -n '/^download_subscription_once() {$/,/^}$/p' "$runtime")"
fail() { echo "FAIL: $*" >&2; exit 1; }
subscription_download_guarded() { shift 2; "$@"; }
# No network: command lookup is deliberately satisfied by this shell function.
curl() {
    output=''; headers=''
    while [ "$#" -gt 0 ]; do
        case "$1" in -o) output="$2"; shift;; -D) headers="$2"; shift;; esac
        shift
    done
    printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
    case "$mode" in
      partial) printf 'vless://partial\n' > "$output"; return 28;;
      oversized) dd if=/dev/zero of="$output" bs=1048577 count=1 2>/dev/null; return $?;;
      declared_large) return 63;;
      complete) printf 'vless://complete\n' > "$output"; return 0;;
    esac
}
original_limit="$(ulimit -f)"
mode=partial
if download_subscription_once https://fixture.invalid "$work/body" '' "$work/headers" ''; then fail 'non-empty truncated response was accepted'; fi
[ "$SUBSCRIPTION_RESOURCE_ERROR" = subscription_download_incomplete ] || fail 'incomplete response lost typed error'
mode=oversized
if download_subscription_once https://fixture.invalid "$work/body" '' "$work/headers" ''; then fail 'over-limit body was accepted'; fi
[ "$SUBSCRIPTION_RESOURCE_ERROR" = subscription_too_large ] || fail 'body cap lost typed error'
[ "$(wc -c < "$work/body")" -le 2097152 ] || fail 'downloader output exceeded child hard cap'
mode=declared_large
if download_subscription_once https://fixture.invalid "$work/body" '' "$work/headers" ''; then fail 'curl size refusal was accepted'; fi
[ "$SUBSCRIPTION_RESOURCE_ERROR" = subscription_too_large ] || fail 'declared length cap lost typed error'
mode=complete
download_subscription_once https://fixture.invalid "$work/body" '' "$work/headers" '' || fail 'small complete body rejected'
[ "$(cat "$work/body")" = 'vless://complete' ] || fail 'complete body changed'
[ "$(ulimit -f)" = "$original_limit" ] || fail 'download limit leaked into parent runtime'
# Both executable branches must preserve their result inside the child guard.
sed -n '/^download_subscription_once() {$/,/^}$/p' "$runtime" | grep -Fq 'download_status=$?' || fail 'downloader exit status not captured'
# Exercise wget fallback with an HTTP failure that still wrote a body.
command() { case "$*" in '-v curl') return 1;; '-v wget') return 0;; *) return 1;; esac; }
wget() {
    output=''
    while [ "$#" -gt 0 ]; do [ "$1" != -O ] || { output="$2"; shift; }; shift; done
    printf 'HTTP error body\n' > "$output"
    return 8
}
if download_subscription_once https://fixture.invalid "$work/body" '' "$work/headers" ''; then fail 'wget HTTP failure body was accepted'; fi
[ "$SUBSCRIPTION_RESOURCE_ERROR" = subscription_download_incomplete ] || fail 'wget failure lost typed error'
echo 'PASS: partial/oversized/declared-large downloads rejected, complete response accepted, parent resource limit unchanged'
