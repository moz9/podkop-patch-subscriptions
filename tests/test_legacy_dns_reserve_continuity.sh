#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_APPLY_LIBRARY_ONLY=1 PODKOP_SECTION_ROOT="$fixture_dir/root" PODKOP_SERVICE_SNAPSHOT_DIR="$fixture_dir/snapshot"
export PODKOP_DNS_APPLY_UCI_FILE="$fixture_dir/podkop"
. "$repo/openwrt/podkop-dns-apply"
. "$repo/openwrt/podkop-section-hooks.sh"
. "$repo/openwrt/podkop-service-snapshot.sh"
command -v dns_reserve_binding >/dev/null || fail 'reserve-only binding transaction missing'
mkdir -p "$fixture_dir/root" "$fixture_dir/snapshot/generation.fixture" "$fixture_dir/rules" "$fixture_dir/backup"
DB_PERSIST="$fixture_dir/backup"; TMP_RULESET_FOLDER="$fixture_dir/rules"
printf '%s\n' "config podkop 'settings'" " option config_path '$fixture_dir/runtime.json'" " option subscription_isolated_section 'main'" " option dns_type 'udp'" " option dns_server '1.1.1.1'" " option bootstrap_dns_server '8.8.8.8'" " option dns_failover_active_slot 'primary'" " option secondary_dns_enabled '0'" "config section 'main'" " option enable_udp_over_tcp '0'" > "$fixture_dir/podkop"
jq -n '{dns:{servers:[{tag:"dns-server",type:"udp",server:"1.1.1.1"},{tag:"bootstrap-dns-server",type:"udp",server:"8.8.8.8"}]},inbounds:[],outbounds:[],route:{rules:[],rule_set:[]}}' > "$fixture_dir/runtime.json"
cp "$fixture_dir/runtime.json" "$fixture_dir/root/worker.json"; cp "$fixture_dir/runtime.json" "$fixture_dir/root/logical.json"; cp "$fixture_dir/runtime.json" "$fixture_dir/root/frontend.json"
printf '{"section":"main","port":19160,"api_port":19163}\n' > "$fixture_dir/root/metadata.json"
printf '{"results":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","checkedAt":1,"expiresAt":2,"services":{"gemini":{"state":"pass"}}}]}\n' > "$fixture_dir/services.json"
saved_show() { awk '
  function clean(s){gsub(/[\047"]/ ,"",s);return s}
  $1=="config"{name=clean($3);print "podkop."name"="clean($2)}
  $1=="option"{print "podkop."name"."clean($2)"="clean($3)}' "$1"; }
dns_reserve_saved_uci() {
  local image="$1" operation="$2" key="${3:-podkop}"
  case "$operation" in export|export_json) cat "$image";; show) saved_show "$image";; get) saved_show "$image" | awk -F= -v key="$key" '$1==key{print $2;found=1}END{exit !found}';; *) return 1;; esac
}
uci() { [ "${1:-}" != -q ] || shift; [ "$1" != changes ] || { cat "$fixture_dir/pending"; return; }; dns_reserve_saved_uci "$fixture_dir/podkop" "$@"; }
ubus() {
  { saved_show "$fixture_dir/podkop"; sed "s/'//g" "$fixture_dir/pending"; } | jq -Rn '
    [inputs | capture("^podkop\\.(?<section>[^.=]+)(?:\\.(?<key>[^=]+))?=(?<value>.*)$")]
    | reduce .[] as $row ({values:{},index:0};
        if $row.key==null then .values[$row.section]={".type":$row.value,".name":$row.section,".anonymous":false,".index":.index}|.index+=1
        else .values[$row.section][$row.key]=$row.value end) | {values}'
}
config_get() { case "$3" in subscription_isolated_section) eval "$1=main";; config_path) eval "$1=\"$fixture_dir/runtime.json\"";; enable_udp_over_tcp) if [ -s "$fixture_dir/pending" ]; then eval "$1=1"; else eval "$1=0"; fi;; *) eval "$1=0";; esac; }
subscription_services_context() { local cached_udp; config_get cached_udp main enable_udp_over_tcp; { jq -cS .dns "$fixture_dir/runtime.json"; uci -q show podkop.settings; printf 'service-web-v2:%s\n' "$cached_udp"; } | sha256sum | awk '{print $1}'; }
subscription_services_cache_path() { printf '%s/services.json\n' "$fixture_dir"; }
sing-box() { return 0; }
dns_apply_load() { :; }
db_reserve_commit_context() { :; }
dns_reserve_export() { cat "$1"; }
podkop_section_ready() { return 0; }
podkop_section_resource_preflight() { return 0; }
: > "$fixture_dir/pending"
podkop_section_context_hash > "$fixture_dir/root/context.sha256"
config="$(dns_apply_hash "$fixture_dir/runtime.json")"; policy="$(subscription_services_snapshot_policy_hash)"; context="$(subscription_services_context main)"
service="$(jq -cS '.results|sort_by(.id)' "$fixture_dir/services.json" | sha256sum | awk '{print $1}')"
jq -n --arg config "$config" --arg policy "$policy" --arg context "$context" --arg service "$service" '{version:1,config:$config,policy:$policy,generation:"generation.fixture",sections:[{section:"main",context:$context,service:$service,admittedIds:["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],admittedLinks:[{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}],rules:[]}' > "$fixture_dir/snapshot/snapshot.json"
cp "$fixture_dir/podkop" "$fixture_dir/uci.before"; cp "$fixture_dir/root/context.sha256" "$fixture_dir/context.before"; cp "$fixture_dir/snapshot/snapshot.json" "$fixture_dir/snapshot.before"
sha256sum "$fixture_dir/runtime.json" "$fixture_dir/root/worker.json" "$fixture_dir/root/logical.json" "$fixture_dir/root/frontend.json" "$fixture_dir/services.json" > "$fixture_dir/runtime.before"
printf '%s\n' "podkop.main.enable_udp_over_tcp='1'" > "$fixture_dir/pending"
dns_reserve_save dot 9.9.9.9 tcp 8.8.4.4 || fail "reserve save failed: $DNS_RESERVE_ERROR"
[ "$(cat "$fixture_dir/pending")" = "podkop.main.enable_udp_over_tcp='1'" ] || fail 'reserve altered unrelated cached UDP draft'
: > "$fixture_dir/pending"
podkop_section_preflight '{"sections":[{"section":"main"}]}' || fail 'reserve invalidated native section preflight'
DA_WORK="$fixture_dir/prepare"; mkdir "$DA_WORK"
jq '.dns.servers' "$fixture_dir/runtime.json" > "$DA_WORK/pair.json"
dns_apply_collect || fail 'reserve invalidated following DNS prepare'
jq -e '.continuity.kind=="reserve-only" and .continuity.freshServiceEvidence==false' "$fixture_dir/snapshot/snapshot.json" >/dev/null || fail 'reserve falsely minted fresh evidence'
sha256sum -c "$fixture_dir/runtime.before" >/dev/null || fail 'reserve changed runtime/membership/service observations'
jq -S 'del(.policy,.continuity)|.sections|=map(del(.context))' "$fixture_dir/snapshot/snapshot.json" > "$fixture_dir/snapshot.same"
jq -S 'del(.policy)|.sections|=map(del(.context))' "$fixture_dir/snapshot.before" > "$fixture_dir/snapshot.old"
cmp "$fixture_dir/snapshot.same" "$fixture_dir/snapshot.old" || fail 'reserve changed admitted evidence'
cp "$fixture_dir/uci.before" "$fixture_dir/podkop"; cp "$fixture_dir/context.before" "$fixture_dir/root/context.sha256"; cp "$fixture_dir/snapshot.before" "$fixture_dir/snapshot/snapshot.json"
reserve_kb="$(du -k "$fixture_dir/podkop" | awk '{print $1}')"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 1000 500 %s 50%% fixture\n' "$((reserve_kb*8+128))"; }
if dns_reserve_save dot 9.9.9.9 tcp 8.8.4.4; then fail 'reserve binding backup space not admitted'; fi
[ "$DNS_RESERVE_ERROR" = insufficient_backup_space ] || fail 'binding backup capacity refusal missing'
unset -f df
dns_apply_atomic() { case "$1" in */context.after) return 1;; *) command cp -p "$1" "$2";; esac; }
if dns_reserve_save dot 9.9.9.9 tcp 8.8.4.4; then fail 'failed binding commit accepted'; fi
[ "$DNS_RESERVE_ERROR" = reserve_context_commit_failed ] || fail 'wrong failed rebind result'
cmp "$fixture_dir/uci.before" "$fixture_dir/podkop" && cmp "$fixture_dir/context.before" "$fixture_dir/root/context.sha256" && cmp "$fixture_dir/snapshot.before" "$fixture_dir/snapshot/snapshot.json" || fail 'failed rebind did not restore exact old images'
printf '%s\n' " option external_active_edit 'changed'" >> "$fixture_dir/podkop"
if dns_reserve_save dot 9.9.9.9 tcp 8.8.4.4; then fail 'stale old context accepted'; fi
[ "$DNS_RESERVE_ERROR" = reserve_context_invalid ] || fail 'stale context not rejected before commit'
echo 'PASS: inactive reserve save preserves native preflight/DNS prepare and rolls back failed rebind'
