#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_CATALOG_DIR="$repo/openwrt"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$work/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$work/persist"
. "$repo/openwrt/podkop-dns-benchmark"
fail() { echo "FAIL: $*" >&2; exit 1; }
db_prepare
race=none
pid_alive() {
    case "$race" in
        finished_at_pid_check|new_run_at_pid_check) cp "$work/replacement.json" "$DB_STATUS";;
        alive) return 0;;
    esac
    return 1
}
# Force the other interleaving: publication after recovery reads its input but
# before a potential recovery mv. Keep the real JSON parser and status function.
jq() {
    case "$race:$*" in
        finished_after_recovery_read:*worker_stopped*)
            result="$(command jq "$@")"
            cp "$work/replacement.json" "$DB_STATUS"
            printf '%s\n' "$result"
            ;;
        *) command jq "$@";;
    esac
}
seed() {
    action="$1"
    command jq -cn --arg action "$action" '{state:"running",action:$action,pid:24680,reportId:"old-run",phase:"full_verify",error:null,selectionComplete:false,fullVerificationComplete:false,recommendation:null,pairResult:null}' > "$DB_STATUS"
    command jq '.state="done"|.phase="complete"|.selectionComplete=true|.fullVerificationComplete=true|.recommendation={success:true}|.pairResult={success:true}' "$DB_STATUS" > "$work/replacement.json"
    cp "$work/replacement.json" "$DB_REPORT"
    cp "$DB_REPORT" "$work/saved-report.json"
}
for action in recommend_reserve recommend_verified bootstrap_test; do
    seed "$action"; race=finished_at_pid_check
    db_status > "$work/response.json"
    command jq -e '.state=="done" and .error==null and .fullVerificationComplete==true' "$work/response.json" >/dev/null || fail "$action terminal success was changed to worker_stopped"
    cmp "$DB_STATUS" "$work/replacement.json" >/dev/null || fail 'terminal status overwritten'
    cmp "$DB_REPORT" "$work/saved-report.json" >/dev/null || fail 'saved report overwritten'

    seed "$action"; race=finished_after_recovery_read
    db_status > "$work/response.json"
    cmp "$DB_STATUS" "$work/replacement.json" >/dev/null || fail "$action recovery rename overwrote newer publication"
    cmp "$DB_REPORT" "$work/saved-report.json" >/dev/null || fail 'saved report overwritten after late publication'
done
seed recommend_reserve
command jq '.state="running"|.pid=24681|.reportId="new-run"' "$work/replacement.json" > "$work/new.json"
mv "$work/new.json" "$work/replacement.json"
race=new_run_at_pid_check
db_status > "$work/response.json"
command jq -e '.state=="running" and .pid==24681 and .reportId=="new-run" and .error==null' "$work/response.json" >/dev/null || fail 'stopped old worker invalidated new worker'
cmp "$DB_STATUS" "$work/replacement.json" >/dev/null || fail 'new worker status overwritten'
# A reused PID still must not let an older report invalidate a newer report.
seed recommend_reserve
command jq '.state="running"|.reportId="new-run"' "$work/replacement.json" > "$work/new.json"
mv "$work/new.json" "$work/replacement.json"
race=new_run_at_pid_check
db_status > "$work/response.json"
command jq -e '.state=="running" and .reportId=="new-run" and .error==null' "$work/response.json" >/dev/null || fail 'report identity was not checked'
seed recommend_verified; race=none
cp "$DB_STATUS" "$work/original.json"
db_status > "$work/response.json"
command jq -e '.state=="error" and .error=="worker_stopped" and .selectionComplete==false and .fullVerificationComplete==false and .recommendation==null and .pairResult==null' "$work/response.json" >/dev/null || fail 'genuinely stopped worker was not rejected'
cmp "$DB_STATUS" "$work/original.json" >/dev/null || fail 'read-only recovery modified stored status'
seed recommend_reserve; race=alive
db_status > "$work/response.json"
command jq -e '.state=="running" and .error==null' "$work/response.json" >/dev/null || fail 'live worker was rejected'
echo 'PASS: status completion races, PID/report identity, read-only recovery and real worker stop'
