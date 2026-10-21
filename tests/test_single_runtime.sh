#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
helper="$PWD/openwrt/podkop-single-runtime"
[ -f "$helper" ] || { echo 'FAIL: single runtime helper missing'; exit 1; }
tmp="$(mktemp -d)"
cleanup() { [ ! -f "$tmp/daemon.pid" ] || kill "$(cat "$tmp/daemon.pid")" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $1" >&2; exit 1; }
export PODKOP_SECTION_ROOT="$tmp/root" PODKOP_SECTION_FRONTEND_CONFIG="$tmp/active.json"
export PODKOP_SECTION_LOCK="$tmp/lock" PODKOP_SECTION_SING_BOX="$(command -v node)"
export PODKOP_SINGLE_INIT="$tmp/bin/main" PODKOP_SECTION_INIT="$tmp/bin/workers"
export PODKOP_SINGLE_SNAPSHOT_MANIFEST="$tmp/snapshot.json"
export PODKOP_MUTATION_LOCK_DIR="$tmp/action.lock.d" PODKOP_MUTATION_LEGACY_LOCK_FILE="$tmp/action.lock"
export SINGLE_TEST_ROOT="$tmp" PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin" "$tmp/root"
cat > "$tmp/source.json" <<'JSON'
{"dns":{"servers":[{"tag":"dns","type":"udp","server":"1.1.1.1"}],"final":"dns"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":21960}],"outbounds":[{"tag":"direct-out","type":"direct"},{"tag":"main-out","type":"selector","outbounds":["main-1-out"]},{"tag":"main-1-out","type":"trojan","server":"192.0.2.1","password":"private"},{"tag":"GEOBLOCK-out","type":"selector","outbounds":["GEOBLOCK-1-out"]},{"tag":"GEOBLOCK-1-out","type":"direct"}],"route":{"final":"direct-out","rules":[{"domain":["a.example"],"outbound":"main-out"}]},"experimental":{"clash_api":{"external_controller":"127.0.0.1:21963"}}}
JSON
ports="$(node -e 'const net=require("net"); const a=net.createServer(),b=net.createServer(); a.listen(0,"127.0.0.1",()=>b.listen(0,"127.0.0.1",()=>{console.log(JSON.stringify([a.address().port,b.address().port]));a.close();b.close();}));')"
jq --argjson ports "$ports" '.inbounds[0].listen_port=$ports[0]|.experimental.clash_api.external_controller=("127.0.0.1:"+($ports[1]|tostring))' "$tmp/source.json" > "$tmp/source-ports.json"
mv "$tmp/source-ports.json" "$tmp/source.json"
cat > "$tmp/check" <<'JS'
const fs=require('fs'); if(fs.existsSync(process.env.SINGLE_TEST_ROOT+'/check-fail')) process.exit(1);
const cfg=JSON.parse(fs.readFileSync(process.argv[3])); if(!cfg.outbounds.length) process.exit(1);
JS
cat > "$tmp/server.js" <<'JS'
const fs=require('fs'),net=require('net'),http=require('http');
const cfg=JSON.parse(fs.readFileSync(process.argv[3]));
net.createServer().listen(cfg.inbounds[0].listen_port,'127.0.0.1');
http.createServer((req,res)=>{res.end(JSON.stringify({version:"test"}));}).listen(Number(cfg.experimental.clash_api.external_controller.split(':').pop()),'127.0.0.1');
JS
cat > "$tmp/bin/main" <<'SH'
#!/bin/sh
echo "$1" >> "$SINGLE_TEST_ROOT/main-calls"
if [ -f "$SINGLE_TEST_ROOT/snapshot-race" ]; then
    rm "$SINGLE_TEST_ROOT/snapshot-race"
    jq '.policy="concurrent-policy"' "$PODKOP_SINGLE_SNAPSHOT_MANIFEST" > "$SINGLE_TEST_ROOT/raced-snapshot"
    mv "$SINGLE_TEST_ROOT/raced-snapshot" "$PODKOP_SINGLE_SNAPSHOT_MANIFEST"
fi
if [ -f "$SINGLE_TEST_ROOT/context-race" ]; then
    rm "$SINGLE_TEST_ROOT/context-race"
    printf 'concurrent-global-draft-marker\n' > "$PODKOP_SECTION_ROOT/context.sha256"
fi
if [ -f "$SINGLE_TEST_ROOT/restart-fail" ]; then rm "$SINGLE_TEST_ROOT/restart-fail"; exit 1; fi
[ ! -f "$SINGLE_TEST_ROOT/daemon.pid" ] || kill "$(cat "$SINGLE_TEST_ROOT/daemon.pid")" 2>/dev/null || true
"$PODKOP_SECTION_SING_BOX" "$SINGLE_TEST_ROOT/server.js" -c "$PODKOP_SECTION_FRONTEND_CONFIG" >/dev/null 2>&1 &
echo "$!" > "$SINGLE_TEST_ROOT/daemon.pid"
SH
cat > "$tmp/bin/workers" <<'SH'
#!/bin/sh
echo "$1" >> "$SINGLE_TEST_ROOT/worker-calls"
case "$1" in stop)
    if [ -f "$SINGLE_TEST_ROOT/async-worker.pid" ]; then
        # procd may delete its instance before the old PID exits.
        rm -f "$SINGLE_TEST_ROOT/workers-running"
        (sleep 2; kill "$(cat "$SINGLE_TEST_ROOT/async-worker.pid")" 2>/dev/null || true) >/dev/null 2>&1 &
    else rm -f "$SINGLE_TEST_ROOT/workers-running"; fi;;
    start) touch "$SINGLE_TEST_ROOT/workers-running";; esac
SH
cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
case "$*" in *podkop-section-worker*) if [ -f "$SINGLE_TEST_ROOT/workers-running" ]; then pid="$(cat "$SINGLE_TEST_ROOT/async-worker.pid" 2>/dev/null || echo 999999999)"; printf '{"podkop-section-worker":{"instances":{"worker":{"running":true,"pid":%s}}}}\n' "$pid"; else echo '{"podkop-section-worker":{"instances":{}}}'; fi;;
*) pid="$(cat "$SINGLE_TEST_ROOT/daemon.pid" 2>/dev/null || echo 0)"; printf '{"sing-box":{"instances":{"main":{"running":true,"pid":%s}}}}\n' "$pid";; esac
SH
chmod +x "$tmp/bin/"*
cat > "$tmp/bin/mv" <<'SH'
#!/bin/sh
if [ -f "$SINGLE_TEST_ROOT/rebind-fail" ] && [ "$2" = "$PODKOP_SINGLE_SNAPSHOT_MANIFEST" ]; then rm "$SINGLE_TEST_ROOT/rebind-fail"; exit 1; fi
if [ -f "$SINGLE_TEST_ROOT/move-fail" ] && [ "$2" = "$PODKOP_SECTION_ROOT/logical.json" ]; then
    case "$1" in */.single-transaction.*/logical.json) rm "$SINGLE_TEST_ROOT/move-fail"; exit 1;; esac
fi
exec /bin/mv "$@"
SH
chmod +x "$tmp/bin/mv"
cd "$tmp"
cp source.json active.json
cp source.json root/logical.json
cp source.json root/frontend.json
cp source.json root/worker.json
echo '{"section":"main","port":19160,"api_port":19163}' > root/metadata.json
old_snapshot_hash="$(sha256sum "$PODKOP_SECTION_FRONTEND_CONFIG" "$PODKOP_SECTION_ROOT/worker.json" "$PODKOP_SECTION_ROOT/logical.json" | sha256sum | awk '{print $1}')"
jq -n --arg sha "$old_snapshot_hash" '{version:1,config:$sha,policy:"preserve-old-policy",generation:"generation.frozen",sections:[],rules:[]}' > snapshot.json
cp snapshot.json before-snapshot.json
touch workers-running check-fail
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' >/dev/null 2>&1; then fail 'invalid migration admitted'; fi
[ ! -f worker-calls ] && [ ! -f main-calls ] || fail 'candidate admission changed service'
[ ! -f root/runtime-mode ] || fail 'invalid candidate activated mode'
rm check-fail
mkdir "$PODKOP_MUTATION_LOCK_DIR"
printf '%s test-owner 0\n' "$$" > "$PODKOP_MUTATION_LOCK_DIR/owner"
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' >/dev/null 2>&1; then fail 'migration bypassed shared action lock'; fi
printf '%s test-owner 0\n' "$$" > "$PODKOP_MUTATION_LEGACY_LOCK_FILE"
touch check-fail
if PODKOP_SINGLE_ACTION_OWNER="$$ $(awk '{print $22}' "/proc/$$/stat")" sh "$helper" migrate source.json '["main","GEOBLOCK"]' > borrowed-output 2>&1; then fail 'borrowed lock admitted invalid candidate'; fi
grep -q candidate_invalid borrowed-output || fail 'verified parent lock rejected'
[ "$(awk 'NR==1{print $1}' "$PODKOP_MUTATION_LEGACY_LOCK_FILE")" = "$$" ] && [ -f "$PODKOP_MUTATION_LOCK_DIR/owner" ] || fail 'helper released borrowed parent lock'
if PODKOP_SINGLE_ACTION_OWNER="$$ 0" sh "$helper" migrate source.json '["main","GEOBLOCK"]' > borrowed-output 2>&1; then fail 'wrong parent identity admitted'; fi
grep -q lock_owner_mismatch borrowed-output || fail 'wrong parent starttime not rejected'
rm check-fail "$PODKOP_MUTATION_LEGACY_LOCK_FILE"
rm "$PODKOP_MUTATION_LOCK_DIR/owner"; rmdir "$PODKOP_MUTATION_LOCK_DIR"
[ ! -f worker-calls ] && [ ! -f main-calls ] || fail 'shared action lock conflict changed services'
mv active.json absent.json
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' >/dev/null 2>&1; then fail 'missing active graph admitted'; fi
mv absent.json active.json
jq '.route.final="user-drift"' source.json > active.json
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' >/dev/null 2>&1; then fail 'active drift overwritten by migration'; fi
[ ! -f worker-calls ] && [ ! -f main-calls ] || fail 'drift guard changed service'
cp source.json active.json
printf '%s\n' '{"sections":[{"section":"main","admittedIds":["old"]}]}' > admitted.json
if PODKOP_SINGLE_SNAPSHOT_MANIFEST="$tmp/admitted.json" sh "$helper" migrate source.json '["main","GEOBLOCK"]' >/dev/null 2>&1; then fail 'nonempty service admission rebound without translation'; fi
[ ! -f worker-calls ] && [ ! -f main-calls ] || fail 'service-admission guard changed runtime'
touch restart-fail
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' >/dev/null 2>&1; then fail 'failed migration admitted'; fi
[ ! -f root/runtime-mode ] && [ -f workers-running ] || fail 'migration rollback lost previous workers/mode'
cmp source.json root/logical.json && cmp source.json active.json || fail 'migration rollback lost graph'
cmp snapshot.json before-snapshot.json || fail 'migration failure changed admission'
touch rebind-fail
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' > rebind-output 2>&1; then fail 'failed snapshot rename admitted'; fi
cmp snapshot.json before-snapshot.json || fail 'snapshot rename failure lost original admission'
[ ! -f root/runtime-mode ] && [ -f workers-running ] || fail 'snapshot failure failed to restore split mode'
cmp source.json root/logical.json && cmp source.json active.json || fail 'snapshot failure lost original graph'
[ -z "$(find root -maxdepth 1 -type d -name '.single-transaction.*' -print)" ] || { cat rebind-output >&2; fail 'successful rollback left blocked recovery'; }
touch snapshot-race
if sh "$helper" migrate source.json '["main","GEOBLOCK"]' > race-output 2>&1; then fail 'concurrent manifest change admitted'; fi
jq -e '.policy=="concurrent-policy"' snapshot.json >/dev/null || fail 'rollback overwrote concurrent manifest'
[ ! -f root/runtime-mode ] && [ -f workers-running ] || fail 'CAS failure failed to restore split mode'
cmp source.json active.json || fail 'CAS failure lost active graph'
cp before-snapshot.json snapshot.json
# A nonempty section-only admission may keep an older global policy. Rebuild
# exact native evidence rows; only platform process/UCI boundaries are mocked.
export PODKOP_SINGLE_CORE="$tmp/native-core"
export SINGLE_SNAPSHOT_SOURCE="$(dirname "$helper")/podkop-service-snapshot.sh"
export SINGLE_SPLIT_SOURCE="$(dirname "$helper")/podkop-section-runtime"
export PODKOP_SECTION_MANAGER="$tmp/bin/proof-manager"
export TMP_RULESET_FOLDER="$tmp/rules"
mkdir -p rules generation.frozen
cat > "$tmp/bin/proof-manager" <<'SH'
#!/bin/sh
[ "$1" != wait-ready ] || { [ -f "$SINGLE_TEST_ROOT/workers-running" ]; exit $?; }
if grep -q '^prepare_preview()' "$SINGLE_SPLIT_SOURCE"; then
    if [ "$#" = 4 ]; then exec sh "$SINGLE_SPLIT_SOURCE" "$@"; fi
    shift; exec sh "$SINGLE_SPLIT_SOURCE" split-one "$@"
else exec sh "$SINGLE_SPLIT_SOURCE" "$@"; fi
SH
chmod +x "$tmp/bin/proof-manager"
cat > native-core <<'SH'
. "$SINGLE_SNAPSHOT_SOURCE"
validate_subscription_urltest_section() { [ "$1" = main ]; }
subscription_required_services_json() { echo '["gemini"]'; }
get_subscription_cache_path() { echo "$SINGLE_TEST_ROOT/native-active"; }
get_subscription_all_cache_path() { echo "$SINGLE_TEST_ROOT/native-all"; }
get_subscription_items_cache_path() { echo "$SINGLE_TEST_ROOT/native-items"; }
get_subscription_link_id() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
subscription_services_cache_path() { echo "$SINGLE_TEST_ROOT/native-evidence"; }
subscription_services_context() { cat "$SINGLE_TEST_ROOT/native-context"; }
podkop_section_names() { echo '["main"]'; }
podkop_section_context_hash() { printf 'v2:'; podkop_section_names | sha256sum | awk '{print $1}'; }
SH
( . "$PODKOP_SINGLE_CORE"; podkop_section_context_hash ) > root/context.sha256
cp root/context.sha256 before-context
for empty_context in exact pending-global; do
    cp root/metadata.json empty-old-metadata
    cp snapshot.json empty-old-snapshot
    if [ "$empty_context" = pending-global ]; then echo saved-global-drift-marker > root/context.sha256; fi
    sh "$helper" migrate source.json '["main","GEOBLOCK"]' || fail 'empty admission context migration'
    if [ "$empty_context" = exact ]; then
        [ "$(cat root/context.sha256)" = "v2:$(printf '["main","GEOBLOCK"]\n' | sha256sum | awk '{print $1}')" ] || fail 'empty admission context names not translated'
    else [ "$(cat root/context.sha256)" = saved-global-drift-marker ] || fail 'empty migration blessed global drift'; fi
    # Rebuild the independent split fixture for the next admission case.
    cp empty-old-metadata root/metadata.json; cp empty-old-snapshot snapshot.json
    cp source.json root/logical.json; cp source.json root/frontend.json; cp source.json root/worker.json; cp source.json active.json
    cp before-context root/context.sha256; rm root/runtime-mode; touch workers-running
    "$tmp/bin/main" restart
done
printf 'private-admitted-link\n' > native-active; cp native-active native-all
echo '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","supported":true}]' > native-items
echo '{"results":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","services":{"gemini":{"state":"pass"}}}]}' > native-evidence
printf '%064d\n' 1 > native-context
printf '{"version":3,"rules":[]}\n' > rules/admitted.json
cp rules/admitted.json generation.frozen/admitted.json
jq --arg path "$tmp/rules/admitted.json" '.route.rule_set=[{type:"local",tag:"admitted",path:$path}]' source.json > new-source
mv new-source source.json; cp source.json root/logical.json
"$PODKOP_SECTION_MANAGER" prepare source.json main 19160 19163 prepared-proof || fail 'native split preparation'
cp prepared-proof/frontend.json root/frontend.json; cp root/frontend.json active.json
cp prepared-proof/worker.json root/worker.json
echo '{"version":2,"allocations":[{"section":"main","port":19160,"api_port":19163}],"sections":[{"section":"main","port":19160,"api_port":19163}]}' > root/metadata.json
mkdir -p root/workers/main
cp root/worker.json root/workers/main/worker.json
"$PODKOP_SECTION_MANAGER" prepare source.json '["main"]' prepared-v2 || fail 'native PE registry preparation'
cp prepared-v2/frontend.json root/frontend.json; cp root/frontend.json active.json
cp prepared-v2/workers/main/worker.json root/workers/main/worker.json
native_runtime_hash() { sha256sum "$PODKOP_SECTION_FRONTEND_CONFIG" "$PODKOP_SECTION_ROOT/logical.json" "$PODKOP_SECTION_ROOT/metadata.json" "$PODKOP_SECTION_ROOT/workers/main/worker.json" | sha256sum | awk '{print $1}'; }
(
    . "$PODKOP_SINGLE_CORE"
    MANIFEST="$tmp/snapshot.json"
    SNAPSHOT_CAPTURE=1 SNAPSHOT_FAILED=0 SNAPSHOT_SECTIONS="$tmp/native-row"
    subscription_services_policy() { cat "$SINGLE_TEST_ROOT/native-evidence" | jq '.required=["gemini"]'; }
    subscription_services_snapshot_section main
    [ "$SNAPSHOT_FAILED" = 0 ] || exit 1
) || fail 'native admission row creation'
old_snapshot_hash="$(native_runtime_hash)"
jq --arg sha "$old_snapshot_hash" --arg rule "$(sha256sum rules/admitted.json | awk '{print $1}')" --slurpfile row native-row '.config=$sha|.policy=("a"*64)|.sections=$row|.rules=[{name:"admitted.json",sha:$rule}]|.continuity={mode:"section-only",section:"main"}' snapshot.json > new-snapshot
mv new-snapshot snapshot.json; cp snapshot.json before-snapshot.json
for invalid in context evidence ram-rule persistent-rule worker; do
    cp native-context saved-context; cp native-evidence saved-evidence
    cp rules/admitted.json saved-rule; cp root/workers/main/worker.json saved-worker
    case "$invalid" in
        context) echo changed > native-context;;
        evidence) jq '.sections[0].evidence[0].services.gemini.state="fail"' before-snapshot.json > snapshot.json;;
        ram-rule) echo changed > rules/admitted.json;;
        persistent-rule) echo changed > generation.frozen/admitted.json;;
        worker) jq '.route.final="unexpected"' saved-worker > root/workers/main/worker.json
            # Exact hash alone is insufficient if the split graph disagrees.
            worker_hash="$(native_runtime_hash)"
            jq --arg sha "$worker_hash" '.config=$sha' before-snapshot.json > snapshot.json;;
    esac
    calls="$(wc -l < main-calls)"
    ! sh "$helper" migrate source.json '["main","GEOBLOCK"]' > native-output 2>&1 || fail "invalid native $invalid admission accepted"
    [ "$(wc -l < main-calls)" = "$calls" ] || fail "invalid native $invalid stopped runtime"
    cp saved-context native-context; cp saved-evidence native-evidence
    cp saved-rule rules/admitted.json; cp saved-rule generation.frozen/admitted.json
    cp saved-worker root/workers/main/worker.json; cp before-snapshot.json snapshot.json
done
"$tmp/bin/main" restart
touch rebind-fail
! sh "$helper" migrate source.json '["main","GEOBLOCK"]' > native-rollback-output 2>&1 || fail 'native rebind failure admitted'
cmp before-context root/context.sha256 || fail 'failed native migration lost original context marker'
cmp before-snapshot.json snapshot.json || fail 'failed native migration lost admission proof'
[ ! -f root/runtime-mode ] && [ -f workers-running ] || fail 'native rollback failed to restore split processes'
touch context-race
! sh "$helper" migrate source.json '["main","GEOBLOCK"]' > native-context-race-output 2>&1 || fail 'context CAS conflict admitted'
[ "$(cat root/context.sha256)" = concurrent-global-draft-marker ] || fail 'rollback overwrote concurrent context change'
cmp before-snapshot.json snapshot.json || fail 'context CAS conflict changed admission proof'
cp before-context root/context.sha256
"$tmp/bin/main" restart
# Evictable observations are not the immutable admission receipt.
echo '{"results":[]}' > native-evidence
sleep 30 &
async_worker_pid="$!"
printf '%s\n' "$async_worker_pid" > async-worker.pid
sh "$helper" migrate source.json '["main","GEOBLOCK"]' || fail 'migration'
[ "$(cat root/context.sha256)" = "v2:$(printf '["main","GEOBLOCK"]\n' | sha256sum | awk '{print $1}')" ] || fail 'new registered-section context not structurally translated'
if kill -0 "$async_worker_pid" 2>/dev/null; then kill "$async_worker_pid" 2>/dev/null || true; fail 'migration returned before owned old worker PID exited'; fi
wait "$async_worker_pid" 2>/dev/null || true
rm async-worker.pid
[ ! -e "$PODKOP_MUTATION_LOCK_DIR" ] && [ ! -e "$PODKOP_MUTATION_LEGACY_LOCK_FILE" ] || fail 'migration leaked shared action lock'
new_snapshot_hash="$(sha256sum "$PODKOP_SECTION_FRONTEND_CONFIG" "$PODKOP_SECTION_ROOT/logical.json" "$PODKOP_SECTION_ROOT/metadata.json" | sha256sum | awk '{print $1}')"
jq -e --arg sha "$new_snapshot_hash" --slurpfile old before-snapshot.json '.config==$sha and del(.config)==($old[0]|del(.config))' snapshot.json >/dev/null || fail 'empty admission not rebound exactly'
[ "$(cat root/runtime-mode)" = single ] || fail 'mode not persisted'
cmp source.json root/logical.json && cmp source.json active.json || fail 'migration changed graph'
sh "$helper" status | jq -e '.ready and .mode=="single" and (.sections|length)==2' >/dev/null || fail 'single status'
sh "$helper" status | jq -e 'all(.sections[];.activeNodeCount==1)' >/dev/null || fail 'working pool counts from actual ready process graph'
echo 'PASS: admission before worker stop; unsplit migration and owned readiness'
oldpid="$(cat daemon.pid)"
jq '(.outbounds[]|select(.tag=="main-1-out")).password="new-private"' source.json > changed.json
sh "$helper" apply changed.json main || fail 'target apply'
[ "$(cat daemon.pid)" != "$oldpid" ] || fail 'apply not activated'
cmp changed.json root/logical.json || fail 'logical not committed'
jq --slurpfile old source.json '.dns==$old[0].dns and .route==$old[0].route and ([.outbounds[]|select(.tag|startswith("GEOBLOCK-"))]==[$old[0].outbounds[]|select(.tag|startswith("GEOBLOCK-"))])' active.json | grep -q true || fail 'non-target changed'
calls="$(wc -l < main-calls)"
sh "$helper" apply changed.json main || fail 'no-op apply'
[ "$(wc -l < main-calls)" = "$calls" ] || fail 'no-op restarted'
jq '.dns.final="changed"' changed.json > bad.json
if sh "$helper" apply bad.json main >/dev/null 2>&1; then fail 'DNS mutation admitted'; fi
[ "$(wc -l < main-calls)" = "$calls" ] || fail 'invalid scoped apply restart'
cp active.json before.json
jq '(.outbounds[]|select(.tag=="main-1-out")).password="failed-private"' changed.json > failed.json
touch restart-fail
if sh "$helper" apply failed.json main >/dev/null 2>&1; then fail 'activation failure admitted'; fi
cmp before.json active.json && cmp changed.json root/logical.json || fail 'failed apply lost graph'
sh "$helper" status | jq -e .ready >/dev/null || fail 'rollback readiness'
echo 'PASS: scoped apply, non-target preservation, no-op and restart rollback'
cat > "$tmp/bin/mv" <<'SH'
#!/bin/sh
if [ -f "$SINGLE_TEST_ROOT/move-fail" ] && [ "$2" = "$PODKOP_SECTION_ROOT/logical.json" ]; then
    case "$1" in */.single-transaction.*/logical.json) rm "$SINGLE_TEST_ROOT/move-fail"; exit 1;; esac
fi
exec /bin/mv "$@"
SH
chmod +x "$tmp/bin/mv"
touch move-fail
if sh "$helper" apply failed.json main >/dev/null 2>&1; then fail 'partial file transaction admitted'; fi
cmp before.json active.json && cmp changed.json root/logical.json || fail 'partial transaction lost graph'
sh "$helper" status | jq -e .ready >/dev/null || fail 'partial transaction rollback readiness'
printf 'MemAvailable:       1000 kB\n' > low-memory
if PODKOP_SINGLE_MEMINFO="$tmp/low-memory" sh "$helper" apply failed.json main >/dev/null 2>&1; then fail 'RAM floor bypass'; fi
echo 'PASS: partial persistence rollback and RAM floor'
(
exec 9>> "$PODKOP_SECTION_LOCK"
flock 9
touch lock-held
sleep 5
) &
holder="$!"
while [ ! -f lock-held ]; do sleep 1; done
if sh "$helper" apply changed.json main >/dev/null 2>&1; then fail 'lock race'; fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
sleep 1
sh "$helper" apply changed.json main || fail 'dead lock owner blocked apply'
mkdir "$PODKOP_SECTION_ROOT/.single-transaction.crash"
if sh "$helper" apply changed.json main >/dev/null 2>&1; then fail 'unrecovered crash silently overwritten'; fi
mv root/runtime-mode root/parked-mode
if sh "$(dirname "$helper")/podkop-section-runtime" bootstrap changed.json '["main","GEOBLOCK"]' > crash-output 2>&1; then fail 'manager bypassed crashed single transaction'; fi
grep -q recovery_required crash-output || fail 'missing marker routed recovery through split manager'
mv root/parked-mode root/runtime-mode
rmdir "$PODKOP_SECTION_ROOT/.single-transaction.crash"
echo 'PASS: concurrent lock excluded'
sh "$helper" bootstrap active.json '[]' || fail 'fresh interface-only config cannot initialize single mode'
sh "$helper" status | jq -e '.ready and .sections==[]' >/dev/null || fail 'empty registry single readiness'
echo 'PASS: single mode supports configs without subscription sections'

