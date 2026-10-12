#!/bin/sh
# Exercise the actual DNS choice handler without any network or router access.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export DA_WORK="$work"
sed -n '/^dns_apply_choices() {$/,/^}$/p' "$repo/openwrt/podkop-dns-apply" > "$work/function"
[ -s "$work/function" ] || fail 'production DNS choice function missing'
. "$work/function"
dns_apply_controller() { printf '%s\n' '127.0.0.1:9090'; }
curl() {
    local destination='' method=GET
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o) destination="$2"; shift;;
            -X) method="$2"; shift;;
        esac
        shift
    done
    [ -n "$destination" ] || return 1
    printf '%s\n' "$method" >> "$work/curl-calls"
    if [ "$method" = PUT ]; then : > "$destination"; return 0; fi
    [ "${http_failure:-0}" = 0 ] || return 1
    cp "$work/http-response" "$destination"
}
cat > "$work/runtime" <<'JSON'
{"outbounds":[{"type":"selector","tag":"S","outbounds":["X","Y"]},{"type":"urltest","tag":"U","outbounds":["X","Y"]}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}
JSON
cat > "$work/valid" <<'JSON'
{"proxies":{"S":{"now":"X","all":["Y","X"]},"U":{"now":"Y","all":["X","Y"]}}}
JSON
for mode in capture restore; do
    for response in empty whitespace multiple scalar null array missing_proxies invalid_proxies missing_group invalid_now invalid_members malformed http_failure; do
        http_failure=0
        case "$response" in
            empty) : > "$work/http-response";;
            whitespace) printf ' \n\t\r ' > "$work/http-response";;
            multiple) cat "$work/valid" "$work/valid" > "$work/http-response";;
            scalar) printf 'true\n' > "$work/http-response";;
            null) printf 'null\n' > "$work/http-response";;
            array) printf '[]\n' > "$work/http-response";;
            missing_proxies) printf '{}\n' > "$work/http-response";;
            invalid_proxies) printf '{"proxies":[]}\n' > "$work/http-response";;
            missing_group) jq 'del(.proxies.U)' "$work/valid" > "$work/http-response";;
            invalid_now) jq '.proxies.S.now=null' "$work/valid" > "$work/http-response";;
            invalid_members) jq '.proxies.U.all=["X"]' "$work/valid" > "$work/http-response";;
            malformed) printf '{"proxies":\n' > "$work/http-response";;
            http_failure) http_failure=1; cp "$work/valid" "$work/http-response";;
        esac
        cp "$work/valid" "$work/saved"
        cp "$work/saved" "$work/saved-before"
        if dns_apply_choices "$mode" "$work/runtime" "$work/saved" > "$work/output" 2> "$work/error"; then
            fail "$mode accepted $response controller response"
        fi
        cmp -s "$work/saved" "$work/saved-before" || fail "$mode changed saved choices on $response response"
    done
    http_failure=0
    cp "$work/valid" "$work/http-response"
    cp "$work/valid" "$work/saved"
    : > "$work/curl-calls"
    dns_apply_choices "$mode" "$work/runtime" "$work/saved" || fail "$mode rejected a valid single controller response"
    cmp -s "$work/saved" "$work/valid" || fail "$mode changed valid choices"
    grep -Fxq GET "$work/curl-calls" || fail "$mode did not verify controller readback"
    [ "$mode" != restore ] || grep -Fxq PUT "$work/curl-calls" || fail 'restore did not set the saved choice'
done
# Invalid runtime or saved evidence must fail before any controller mutation.
for input in empty whitespace multiple scalar null array missing_shape malformed; do
    case "$input" in
        empty) : > "$work/invalid";;
        whitespace) printf ' \n\t ' > "$work/invalid";;
        multiple) cat "$work/runtime" "$work/runtime" > "$work/invalid";;
        scalar) printf 'true\n' > "$work/invalid";;
        null) printf 'null\n' > "$work/invalid";;
        array) printf '[]\n' > "$work/invalid";;
        missing_shape) printf '{}\n' > "$work/invalid";;
        malformed) printf '{\n' > "$work/invalid";;
    esac
    for mode in capture restore; do
        cp "$work/valid" "$work/saved"
        : > "$work/curl-calls"
        if dns_apply_choices "$mode" "$work/invalid" "$work/saved" >/dev/null 2>&1; then fail "$mode accepted $input runtime"; fi
        [ ! -s "$work/curl-calls" ] || fail "$mode contacted controller with $input runtime"
        cmp -s "$work/saved" "$work/valid" || fail "$mode changed saved choices with $input runtime"
    done
    [ "$input" != multiple ] || cat "$work/valid" "$work/valid" > "$work/invalid"
    : > "$work/curl-calls"
    if dns_apply_choices restore "$work/runtime" "$work/invalid" >/dev/null 2>&1; then fail "restore accepted $input saved choices"; fi
    [ ! -s "$work/curl-calls" ] || fail "restore contacted controller with $input saved choices"
done
for saved_shape in 'del(.proxies.S)' '.proxies.S.now=null'; do
    jq "$saved_shape" "$work/valid" > "$work/invalid"
    : > "$work/curl-calls"
    if dns_apply_choices restore "$work/runtime" "$work/invalid" >/dev/null 2>&1; then fail 'restore accepted a missing saved selection'; fi
    [ ! -s "$work/curl-calls" ] || fail 'restore mutated controller without a saved selection'
done
# A real runtime without selectable groups still needs no controller request.
printf '{"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$work/no-groups"
for mode in capture restore; do
    cp "$work/valid" "$work/saved"
    : > "$work/curl-calls"
    dns_apply_choices "$mode" "$work/no-groups" "$work/saved" || fail "$mode rejected a valid no-group runtime"
    [ ! -s "$work/curl-calls" ] || fail "$mode contacted controller for a no-group runtime"
    if [ "$mode" = capture ]; then jq -e '.=={proxies:{}}' "$work/saved" >/dev/null || fail 'no-group capture changed'; fi
done
cp "$work/valid" "$work/saved"
jq '.proxies.S.now="Y"' "$work/valid" > "$work/http-response"
if dns_apply_choices restore "$work/runtime" "$work/saved" >/dev/null 2>&1; then fail 'restore accepted the wrong selected member'; fi
printf 'PASS: DNS choices require one valid controller response and verified restoration with %s\n' "$(jq --version)"
