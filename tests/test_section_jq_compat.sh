#!/bin/sh
# Exercise the real split transform with the installed jq, including 1.6 in CI.
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$repo/openwrt/podkop-section-runtime"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export PODKOP_SECTION_MODE=split PODKOP_SECTION_ROOT="$work/root"
mkdir "$PODKOP_SECTION_ROOT"

# jq 1.7 accepts keyword-shaped variables that jq 1.6 rejects. Inspect the
# entire native filter so function arguments and local bindings are covered,
# not just command-line --arg/--argjson bindings. Shell variables elsewhere
# in the helper are not jq identifiers and must not cause false positives.
awk '/if ! jq -e --arg s / { capture=1 }
     capture { print }
     capture && /"\$logical" >/ { exit }' "$helper" > "$work/native-filter"
grep -q 'def require(' "$work/native-filter" || fail 'native split filter not found'
reserved='as|def|module|import|include|if|then|else|elif|end|and|or|reduce|foreach|try|catch|label|break'
if grep -Eq -- "\\\$($reserved)([^[:alnum:]_]|$)|--(arg|argjson|slurpfile|rawfile)[[:space:]]+($reserved)([[:space:]]|$)" "$work/native-filter"; then
    fail 'jq 1.6 reserved variable in native split filter'
fi

cat > "$work/logical.json" <<'JSON'
{"dns":{"servers":[{"type":"udp","tag":"dns","server":"1.1.1.1"}],"final":"dns"},"outbounds":[{"type":"direct","tag":"direct-out"},{"type":"selector","tag":"Main-out","outbounds":["Main-1-out"]},{"type":"socks","tag":"Main-1-out","server":"192.0.2.1","server_port":1080}],"route":{"final":"direct-out"},"experimental":{}}
JSON

# Legacy calls this prepare; PE exposes the same transform as split-one.
command=prepare
if grep -q '^split_one()' "$helper"; then command=split-one; fi
sh "$helper" "$command" "$work/logical.json" Main 19160 19163 "$work/prepared" || fail 'valid native graph did not compile and prepare'
cmp -s "$work/logical.json" "$work/prepared/logical.json" || fail 'logical graph changed'
jq -e --slurpfile source "$work/logical.json" '
    .dns==$source[0].dns and .route==$source[0].route and
    .experimental==$source[0].experimental and
    .outbounds==[$source[0].outbounds[0],{type:"socks",tag:"Main-out",server:"127.0.0.1",server_port:19160,version:"5",routing_mark:2097152}]
' "$work/prepared/frontend.json" >/dev/null || fail 'frontend split graph changed'
jq -e '
    .route.final=="Main-out" and .route.default_mark==2097152 and
    .inbounds[0].listen=="127.0.0.1" and .inbounds[0].listen_port==19160 and
    .experimental.clash_api.external_controller=="127.0.0.1:19163" and
    any(.outbounds[]; .tag=="Main-out" and .outbounds==["Main-1-out"]) and
    any(.outbounds[]; .tag=="Main-1-out" and .routing_mark==2097152)
' "$work/prepared/worker.json" >/dev/null || fail 'private worker split graph changed'

printf '{}\n' > "$work/invalid.json"
if sh "$helper" "$command" "$work/invalid.json" Main 19160 19163 "$work/rejected" > "$work/error" 2>&1; then
    fail 'invalid schema admitted'
fi
grep -Fqx 'section_runtime: section_graph/schema' "$work/error" || fail 'invalid schema lost its precise graph error'
[ ! -e "$work/rejected" ] || fail 'invalid graph exposed a prepared candidate'
printf 'PASS: native section graph prepares and rejects safely with %s; jq reserved variables absent\n' "$(jq --version)"
