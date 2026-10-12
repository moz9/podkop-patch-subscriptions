#!/bin/sh
set -eu
# Explicit compatibility fixture for the former split worker architecture.
export PODKOP_SECTION_MODE=split
cd "$(dirname "$0")/.."
helper="$PWD/openwrt/podkop-section-runtime"
tmp="$(mktemp -d)"
cleanup_test() {
    for state in "$tmp/daemon.pid" "$tmp/idle.pid" "$tmp/lock-holder.pid"; do
        [ ! -f "$state" ] || kill "$(cat "$state")" 2>/dev/null || true
    done
    rm -rf "$tmp"
}
trap cleanup_test EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ -f "$helper" ] || fail 'section isolation prepare is not implemented'
export SECTION_TEST_REAL_JQ="$(command -v jq)"
mkdir "$tmp/jq-bin"
cat > "$tmp/jq-bin/jq" <<'SH'
#!/bin/sh
# OpenWrt office jq is built without ONIGURUMA. Transform must not need it.
case "$*" in *'test('*|*'match('*|*'sub('*|*'gsub('*) printf '%s\n' 'jq_regex_unavailable' >&2; exit 1;; esac
exec "$SECTION_TEST_REAL_JQ" "$@"
SH
chmod +x "$tmp/jq-bin/jq"
export PATH="$tmp/jq-bin:$PATH"
cat > "$tmp/source.json" <<'JSON'
{"log":{"level":"warn"},"dns":{"servers":[{"type":"udp","tag":"bootstrap","server":"1.1.1.1"},{"type":"https","tag":"dns-main","server":"dns.example","domain_resolver":"bootstrap"},{"type":"fakeip","tag":"fakeip","inet4_range":"198.18.0.0/15"}],"rules":[{"rule_set":["GeoBlock"],"server":"fakeip"}],"final":"dns-main","independent_cache":true},"inbounds":[{"type":"tproxy","tag":"tproxy-in","listen":"::","listen_port":1602}],"outbounds":[{"type":"direct","tag":"direct-out"},{"type":"selector","tag":"Main-out","outbounds":["Main-urltest-out","Main-1-out"],"default":"Main-urltest-out"},{"type":"urltest","tag":"Main-urltest-out","outbounds":["Main-1-out","Main-2-out"],"url":"https://test.example/generate_204","interval":"3m","tolerance":80,"interrupt_exist_connections":false},{"type":"trojan","tag":"Main-1-out","server":"node.example","server_port":443,"password":"test-private","tls":{"enabled":true}},{"type":"vless","tag":"Main-2-out","server":"192.0.2.2","server_port":443,"uuid":"private"},{"type":"selector","tag":"GeoBlock-out","outbounds":["GeoBlock-1-out"]},{"type":"shadowsocks","tag":"GeoBlock-1-out","server":"geo.example","server_port":443,"password":"private"}],"route":{"final":"direct-out","default_domain_resolver":"dns-main","auto_detect_interface":true,"rules":[{"rule_set":["GeoBlock"],"outbound":"GeoBlock-out"},{"domain":["main.example"],"outbound":"Main-out"}],"rule_set":[{"type":"local","tag":"GeoBlock","path":"/tmp/rules.srs"}]},"experimental":{"cache_file":{"enabled":true,"path":"/etc/sing-box/cache.db","store_fakeip":true},"clash_api":{"external_controller":"127.0.0.1:9090"}}}
JSON
sh "$helper" prepare "$tmp/source.json" Main 19160 19163 "$tmp/prepared" || fail 'prepare valid graph'
jq -e --slurpfile source "$tmp/source.json" '
  .dns == $source[0].dns and .inbounds == $source[0].inbounds and
  .route == $source[0].route and .experimental == $source[0].experimental and
  ([.outbounds[]|select(.tag|startswith("GeoBlock"))] == [$source[0].outbounds[]|select(.tag|startswith("GeoBlock"))]) and
  ([.outbounds[]|select(.tag=="Main-out")] == [{type:"socks",tag:"Main-out",server:"127.0.0.1",server_port:19160,version:"5",routing_mark:2097152}]) and
  ([.outbounds[]|select(.tag|startswith("Main-"))]|length)==1
' "$tmp/prepared/frontend.json" >/dev/null || fail 'frontend must preserve shared state'
jq -e --slurpfile source "$tmp/source.json" '
  ([.outbounds[]|select(.tag=="Main-urltest-out")] == [$source[0].outbounds[]|select(.tag=="Main-urltest-out")]) and
  .inbounds==[{type:"socks",tag:"section-in",listen:"127.0.0.1",listen_port:19160}] and
  .route.final=="Main-out" and .route.auto_detect_interface==true and .route.default_mark==2097152 and
  (.route|has("rule_set")|not) and (.route|has("rules")|not) and
  ([.dns.servers[]|select(.type=="fakeip")]|length)==0 and
  (.dns|has("rules")|not) and (.experimental|has("cache_file")|not) and
  .experimental.clash_api.external_controller=="127.0.0.1:19163" and
  ([.outbounds[]|select(.type!="selector" and .type!="urltest")|.routing_mark]|all(.==2097152))
' "$tmp/prepared/worker.json" >/dev/null || fail 'worker private DNS real urltest and marks'
cmp "$tmp/source.json" "$tmp/prepared/logical.json" || fail 'logical config preserved exactly'
[ "$(stat -c %a "$tmp/prepared/worker.json")" = 600 ] || fail 'worker permissions'
reject() {
    jq "$2" "$tmp/source.json" > "$tmp/invalid.json"
    if sh "$helper" prepare "$tmp/invalid.json" Main 19160 19163 "$tmp/bad-$1" > "$tmp/output" 2>&1; then fail "must reject $1"; fi
    [ ! -e "$tmp/bad-$1/worker.json" ] || fail 'failed prepare exposed candidate'
    ! grep -q 'test-private' "$tmp/output" || fail 'credentials exposed'
}
reject cross_detour '(.outbounds[]|select(.tag=="Main-1-out")).detour="GeoBlock-out"'
reject cross_group '(.outbounds[]|select(.tag=="Main-out")).outbounds += ["GeoBlock-out"]'
reject missing_member '.outbounds|=map(select(.tag!="Main-2-out"))'
reject unsupported_tag '.outbounds += [{type:"direct",tag:"Main-backup-out"}]'
reject dns_cross_detour '.dns.servers[0].detour="GeoBlock-out"'
reject dns_missing '.dns.servers[1].domain_resolver="absent"'
reject fakeip_dependency '(.outbounds[]|select(.tag=="Main-1-out")).domain_resolver="fakeip"'
reject invalid_default '(.outbounds[]|select(.tag=="Main-out")).default="absent"'
reject duplicate_tag '.outbounds += [.outbounds[1]]'
reject frontend_dependency '.route.rules += [{domain:["other.example"],outbound:"Main-1-out"}]'
reject frontend_detour '(.outbounds[]|select(.tag=="GeoBlock-1-out")).detour="Main-1-out"'
reject frontend_group '(.outbounds[]|select(.tag=="GeoBlock-out")).outbounds += ["Main-2-out"]'
reject no_group '.outbounds|=map(select(.tag!="Main-out"))'
reject group_cycle '(.outbounds[]|select(.tag=="Main-urltest-out")).outbounds=["Main-out"]'
reject dns_cycle '.dns.servers[0].domain_resolver="dns-main"'
reject urltest_type '(.outbounds[]|select(.tag=="Main-urltest-out")).type="selector"'
if sh "$helper" prepare "$tmp/source.json" 'Main.*' 19160 19163 "$tmp/bad-name" > /dev/null 2>&1; then fail 'unsafe section name'; fi
if sh "$helper" prepare "$tmp/source.json" Main 19160 19160 "$tmp/bad-ports" > /dev/null 2>&1; then fail 'colliding ports'; fi
printf 'PASS: section graph isolation and fail-closed dependencies\n'

# Only the external daemon/procd boundary is doubled. Graph transformation,
# filesystem admission, atomic replacements and rollback run in the real helper.
mkdir "$tmp/bin"
export PODKOP_SECTION_ROOT="$tmp/persist"
export PODKOP_SECTION_FRONTEND_CONFIG="$tmp/active.json"
export PODKOP_SECTION_INIT="$tmp/bin/worker-init"
export PODKOP_SECTION_SING_BOX="$tmp/bin/sing-box"
export PODKOP_SECTION_LOCK="$tmp/section.lock"
export SECTION_TEST_ROOT="$tmp"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = check ] || exit 1
[ "$2" = -c ] || exit 1
[ ! -e "$SECTION_TEST_ROOT/check-fail" ] || exit 1
jq -e '.outbounds|length>0' "$3" >/dev/null
SH
cat > "$tmp/bin/worker-init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$SECTION_TEST_ROOT/init-calls"
if [ -e "$SECTION_TEST_ROOT/restart-fail" ]; then rm "$SECTION_TEST_ROOT/restart-fail"; exit 1; fi
exit 0
SH
cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' '{"podkop-section-worker":{"instances":{"worker":{"running":false,"pid":0}}}}'
SH
chmod +x "$tmp/bin"/*
sh "$helper" bootstrap "$tmp/source.json" Main || fail 'bootstrap admitted state'
mkdir "$PODKOP_SECTION_ROOT/.lock"
sh "$helper" bootstrap "$tmp/source.json" Main || fail 'reboot leftover persistent lock must be ignored'
rmdir "$PODKOP_SECTION_ROOT/.lock"
printf '%s\n' '99999999 0' > "$PODKOP_SECTION_LOCK"
sh "$helper" bootstrap "$tmp/source.json" Main || fail 'dead lock owner record blocked recovery'
(
    exec 9>> "$PODKOP_SECTION_LOCK"
    flock 9
    touch "$tmp/lock-held"
    exec sleep 1000
) &
printf '%s\n' "$!" > "$tmp/lock-holder.pid"
for attempt in 1 2 3 4 5; do [ -f "$tmp/lock-held" ] && break; sleep 1; done
[ -f "$tmp/lock-held" ] || fail 'active lock setup'
if sh "$helper" bootstrap "$tmp/source.json" Main > /dev/null 2>&1; then fail 'active lock was not excluded'; fi
kill -KILL "$(cat "$tmp/lock-holder.pid")"
wait "$(cat "$tmp/lock-holder.pid")" 2>/dev/null || true
rm "$tmp/lock-holder.pid"
sleep 1
sh "$helper" bootstrap "$tmp/source.json" Main || fail 'SIGKILL left permanent lock'
rm "$PODKOP_SECTION_LOCK"
sh "$helper" bootstrap "$tmp/source.json" Main || fail 'volatile lock disappearance reboot recovery'
printf 'PASS: active lock exclusion and crash/reboot recovery\n'
for f in worker logical frontend metadata; do [ -f "$PODKOP_SECTION_ROOT/$f.json" ] || fail "bootstrap $f"; done
[ ! -e "$tmp/init-calls" ] || fail 'bootstrap must not restart services'
jq -e '.section=="Main" and .port==19160 and .api_port==19163' "$PODKOP_SECTION_ROOT/metadata.json" >/dev/null || fail 'bootstrap metadata'
cp "$PODKOP_SECTION_ROOT/frontend.json" "$PODKOP_SECTION_FRONTEND_CONFIG"
cp "$PODKOP_SECTION_ROOT/worker.json" "$tmp/old-worker.json"
cp "$PODKOP_SECTION_ROOT/logical.json" "$tmp/old-logical.json"
jq '(.outbounds[]|select(.tag=="Main-1-out")).password="new-private"' "$tmp/source.json" > "$tmp/new-logical.json"
touch "$tmp/restart-fail"
if sh "$helper" apply "$tmp/new-logical.json" Main > "$tmp/output" 2>&1; then fail 'restart failure accepted'; fi
cmp "$tmp/old-worker.json" "$PODKOP_SECTION_ROOT/worker.json" || fail 'worker rollback'
cmp "$tmp/old-logical.json" "$PODKOP_SECTION_ROOT/logical.json" || fail 'failed apply preserved logical'
[ "$(wc -l < "$tmp/init-calls" | tr -d ' ')" = 2 ] || fail 'rollback must restart old worker'
! grep -q 'private' "$tmp/output" || fail 'apply logs credentials'
jq '.route.rules += [{domain:["changed.example"],outbound:"direct-out"}]' "$tmp/new-logical.json" > "$tmp/route-change.json"
if sh "$helper" apply "$tmp/route-change.json" Main > /dev/null 2>&1; then fail 'frontend mismatch accepted'; fi
[ "$(wc -l < "$tmp/init-calls" | tr -d ' ')" = 2 ] || fail 'frontend mismatch started worker'
if sh "$helper" apply "$tmp/new-logical.json" GeoBlock > /dev/null 2>&1; then fail 'metadata mismatch accepted'; fi
jq -e '.ready==false and .section=="Main" and .pid==0' <<JSON >/dev/null || fail 'unready status'
$(sh "$helper" status)
JSON
touch "$tmp/check-fail"
if sh "$helper" bootstrap "$tmp/new-logical.json" Main > /dev/null 2>&1; then fail 'invalid sing-box candidate bootstrap'; fi
cmp "$tmp/old-logical.json" "$PODKOP_SECTION_ROOT/logical.json" || fail 'failed bootstrap replaced state'
printf 'PASS: bootstrap admission, worker rollback, metadata and frontend guard\n'

rm "$tmp/check-fail"
node_bin="$(command -v node)"
export PODKOP_SECTION_SING_BOX="$node_bin"
cat > "$tmp/check" <<'JS'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[3]));
if (!Array.isArray(cfg.outbounds) || !cfg.outbounds.length) process.exit(1);
JS
cat > "$tmp/server.js" <<'JS'
const fs = require('fs'), net = require('net');
const cfg = JSON.parse(fs.readFileSync(process.argv[3]));
net.createServer().listen(cfg.inbounds[0].listen_port, '127.0.0.1');
net.createServer().listen(Number(cfg.experimental.clash_api.external_controller.split(':')[1]), '127.0.0.1');
JS
cat > "$tmp/idle.js" <<'JS'
setInterval(() => {}, 1000);
JS
cat > "$tmp/bin/worker-init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$SECTION_TEST_ROOT/init-calls"
if [ -f "$SECTION_TEST_ROOT/daemon.pid" ]; then kill "$(cat "$SECTION_TEST_ROOT/daemon.pid")" 2>/dev/null || true; fi
"$PODKOP_SECTION_SING_BOX" "$SECTION_TEST_ROOT/server.js" -c "$PODKOP_SECTION_ROOT/worker.json" >/dev/null 2>&1 &
printf '%s\n' "$!" > "$SECTION_TEST_ROOT/daemon.pid"
cp "$SECTION_TEST_ROOT/daemon.pid" "$SECTION_TEST_ROOT/reported.pid"
SH
cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
pid="$(cat "$SECTION_TEST_ROOT/reported.pid")"
printf '{"podkop-section-worker":{"instances":{"worker":{"running":true,"pid":%s}}}}\n' "$pid"
SH
chmod +x "$tmp/bin/worker-init" "$tmp/bin/ubus"
cd "$tmp"
"$PODKOP_SECTION_INIT" restart
sh "$helper" wait-ready || fail 'owned real listeners readiness'
old_pid="$(cat "$tmp/daemon.pid")"
sh "$helper" status | jq -e --argjson pid "$old_pid" '.ready and .pid==$pid' >/dev/null || fail 'owned service PID status'
"$node_bin" "$tmp/idle.js" -c "$PODKOP_SECTION_ROOT/worker.json" >/dev/null 2>&1 &
printf '%s\n' "$!" > "$tmp/idle.pid"
cp "$tmp/idle.pid" "$tmp/reported.pid"
sh "$helper" status | jq -e '.ready==false and .pid==0' >/dev/null || fail 'unowned listeners accepted'
cp "$tmp/daemon.pid" "$tmp/reported.pid"
sh "$helper" apply "$tmp/new-logical.json" Main || fail 'worker-only successful apply'
[ "$(cat "$tmp/daemon.pid")" != "$old_pid" ] || fail 'changed worker did not restart'
cmp "$tmp/new-logical.json" "$PODKOP_SECTION_ROOT/logical.json" || fail 'successful logical persistence'
sh "$helper" status | jq -e '.ready' >/dev/null || fail 'new worker readiness'
jq '.outbounds|=reverse' "$tmp/new-logical.json" > "$tmp/reordered.json"
calls="$(wc -l < "$tmp/init-calls")"
sh "$helper" apply "$tmp/reordered.json" Main || fail 'semantic no-op apply'
[ "$(wc -l < "$tmp/init-calls")" = "$calls" ] || fail 'equivalent worker restarted'
printf 'PASS: real service PID/listener ownership, successful apply and no-op\n'

cp "$PODKOP_SECTION_ROOT/worker.json" "$tmp/before-worker.json"
cp "$PODKOP_SECTION_ROOT/logical.json" "$tmp/before-logical.json"
cp "$PODKOP_SECTION_ROOT/frontend.json" "$tmp/before-frontend.json"
jq '(.outbounds[]|select(.tag=="Main-1-out")).password="another-private"' "$tmp/new-logical.json" > "$tmp/final-candidate.json"
cat > "$tmp/bin/mv" <<'SH'
#!/bin/sh
if [ -f "$SECTION_TEST_ROOT/move-fail" ] && [ "$2" = "$PODKOP_SECTION_ROOT/logical.json" ]; then
    case "$1" in */prepared/logical.json)
        rm "$SECTION_TEST_ROOT/move-fail"
        exit 1;;
    esac
fi
if [ -f "$SECTION_TEST_ROOT/move-hup" ] && [ "$2" = "$PODKOP_SECTION_ROOT/logical.json" ]; then
    case "$1" in */prepared/logical.json)
        rm "$SECTION_TEST_ROOT/move-hup"
        kill -HUP "$PPID"
        exit 1;;
    esac
fi
exec /bin/mv "$@"
SH
chmod +x "$tmp/bin/mv"
touch "$tmp/move-fail"
if sh "$helper" apply "$tmp/final-candidate.json" Main > /dev/null 2>&1; then fail 'failed logical persist accepted'; fi
cmp "$tmp/before-worker.json" "$PODKOP_SECTION_ROOT/worker.json" || fail 'final persist failure worker rollback'
cmp "$tmp/before-logical.json" "$PODKOP_SECTION_ROOT/logical.json" || fail 'final persist failure logical rollback'
sh "$helper" status | jq -e '.ready' >/dev/null || fail 'rollback worker readiness'
touch "$tmp/move-fail"
if sh "$helper" bootstrap "$tmp/final-candidate.json" Main > /dev/null 2>&1; then fail 'partial bootstrap accepted'; fi
cmp "$tmp/before-worker.json" "$PODKOP_SECTION_ROOT/worker.json" || fail 'partial bootstrap worker rollback'
cmp "$tmp/before-frontend.json" "$PODKOP_SECTION_ROOT/frontend.json" || fail 'partial bootstrap frontend rollback'
cmp "$tmp/before-logical.json" "$PODKOP_SECTION_ROOT/logical.json" || fail 'partial bootstrap logical rollback'
printf 'PASS: final persistence failure and partial bootstrap rollback\n'
touch "$tmp/move-hup"
if sh "$helper" apply "$tmp/final-candidate.json" Main > /dev/null 2>&1; then fail 'interrupted apply accepted'; fi
cmp "$tmp/before-worker.json" "$PODKOP_SECTION_ROOT/worker.json" || fail 'HUP worker rollback'
cmp "$tmp/before-logical.json" "$PODKOP_SECTION_ROOT/logical.json" || fail 'HUP logical rollback'
[ ! -e "$PODKOP_SECTION_ROOT/.lock" ] || fail 'signal left lock'
sh "$helper" status | jq -e '.ready' >/dev/null || fail 'signal rollback readiness'
printf 'PASS: interrupted apply rollback\n'

# Exercise procd command admission without starting another daemon.
. "$(dirname "$helper")/podkop-section-worker.init"
uci() { printf '%s\n' "$section_test_uci"; }
procd_open_instance() { printf 'instance %s\n' "$1" >> "$tmp/procd-calls"; }
procd_set_param() { printf '%s\n' "$*" >> "$tmp/procd-calls"; }
procd_close_instance() { :; }
section_test_uci=Main
start_service || fail 'init admitted loopback worker'
grep -F "command $node_bin run -c $PODKOP_SECTION_ROOT/worker.json" "$tmp/procd-calls" >/dev/null || fail 'init exact worker command'
grep -F 'instance worker' "$tmp/procd-calls" >/dev/null || fail 'init named procd instance'
grep -F 'stdout 0' "$tmp/procd-calls" >/dev/null || fail 'init disabled stdout'
grep -F 'stderr 0' "$tmp/procd-calls" >/dev/null || fail 'init disabled stderr'
calls="$(wc -l < "$tmp/procd-calls")"
section_test_uci=GeoBlock
if start_service; then fail 'init mismatched UCI admitted'; fi
[ "$(wc -l < "$tmp/procd-calls")" = "$calls" ] || fail 'mismatched UCI started instance'
section_test_uci=""
start_service || fail 'disabled opt-in init'
section_test_uci=Main
jq '.inbounds[0].listen="0.0.0.0"' "$PODKOP_SECTION_ROOT/worker.json" > "$tmp/unsafe.json"
/bin/mv "$tmp/unsafe.json" "$PODKOP_SECTION_ROOT/worker.json"
if start_service; then fail 'init LAN listener admitted'; fi
printf 'PASS: opt-in procd admission and loopback enforcement\n'
