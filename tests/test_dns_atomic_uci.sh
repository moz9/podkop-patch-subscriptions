#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
PODKOP_DNS_APPLY_LIBRARY_ONLY=1
. "$repo/openwrt/podkop-dns-apply"
fail() { echo "FAIL: $*" >&2; exit 1; }
DA_WORK="$work/transaction"; mkdir "$DA_WORK"
DA_UCI="$work/podkop"; DA_SAVED=0
DA_TYPE=dot; DA_SERVER=9.9.9.9; DA_BOOT_TYPE=tcp; DA_BOOT_SERVER=8.8.8.8
PODKOP_DNS_APPLY_UCI_FILE="$DA_UCI"
fixture_pending="$work/pending"; mutations="$work/mutations"
uci() {
    [ "${1:-}" != -q ] || shift
    case "$1" in
      changes) [ ! -f "$work/changes-fail" ] || return 1; cat "$fixture_pending";;
      export)
        [ ! -f "$work/parse-fail" ] || return 1
        cat <&3
        if [ -f "$work/race-draft" ]; then
            printf "podkop.settings.dns_server='draft.invalid'\n" > "$fixture_pending"
        fi;;
      set|commit|revert|delete|import) echo "$1" >> "$mutations"; return 0;;
      *) return 1;;
    esac
}
config_load() { :; }
reset_case() {
    rm -f "$work/parse-fail" "$work/race-draft" "$work/changes-fail" "$DA_WORK/uci-written.sha"
    : > "$fixture_pending"; : > "$mutations"
    cat > "$DA_UCI" <<'CONFIG'
# retain this formatting and comment
config settings 'settings'
 option dns_type 'doh'
 option dns_server 'old.example/dns-query'
 option bootstrap_dns_type 'udp'
 option bootstrap_dns_server '1.1.1.1'
 option dns_failover_active_slot 'secondary'
 option unrelated 'keep me'

config section 'main'
 list selected_nodes 'keep-node'
CONFIG
    cp "$DA_UCI" "$DA_WORK/before.1"
    sha256sum "$DA_UCI" | awk '{print $1}' > "$DA_WORK/before.1.sha"
    printf '1|uci|%s\n' "$DA_UCI" > "$DA_WORK/files"
}
reset_case
dns_apply_uci_set || fail 'clean DNS write failed'
[ ! -s "$mutations" ] || fail 'DNS write used shared UCI set/commit/revert'
grep -q "option dns_server '9.9.9.9'" "$DA_UCI" || fail 'primary not saved'
grep -q "option bootstrap_dns_server '8.8.8.8'" "$DA_UCI" || fail 'bootstrap not saved'
grep -q "option dns_failover_active_slot 'primary'" "$DA_UCI" || fail 'slot not saved'
grep -Fxq '# retain this formatting and comment' "$DA_UCI" || fail 'comment changed'
grep -Fxq " option unrelated 'keep me'" "$DA_UCI" || fail 'unrelated option changed'
grep -Fxq "config section 'main'" "$DA_UCI" || fail 'peer section changed'
grep -Fxq " list selected_nodes 'keep-node'" "$DA_UCI" || fail 'subscription selection changed'
dns_apply_uci_strip "$DA_WORK/before.1" > "$work/unrelated.before"
dns_apply_uci_strip "$DA_UCI" > "$work/unrelated.after"
cmp -s "$work/unrelated.before" "$work/unrelated.after" || fail 'unrelated bytes changed'

reset_case
printf "podkop.main.description='unrelated draft'\n" > "$fixture_pending"
cp "$fixture_pending" "$work/pending.expected"
! dns_apply_uci_set || fail 'new draft accepted without applied-context proof'
cmp -s "$DA_UCI" "$DA_WORK/before.1" || fail 'draft conflict wrote committed config'
cmp -s "$fixture_pending" "$work/pending.expected" || fail 'draft was discarded'

reset_case
touch "$work/race-draft"
! dns_apply_uci_set || fail 'draft arriving during preparation was committed'
cmp -s "$DA_UCI" "$DA_WORK/before.1" || fail 'race changed committed file'
grep -q draft.invalid "$fixture_pending" || fail 'racing draft lost'
[ ! -s "$mutations" ] || fail 'race called shared UCI mutation'

reset_case
printf "# external saved edit\n" >> "$DA_UCI"
cp "$DA_UCI" "$work/external"
! dns_apply_uci_set || fail 'committed input drift accepted'
cmp -s "$DA_UCI" "$work/external" || fail 'external saved edit overwritten'

reset_case
touch "$work/parse-fail"
! dns_apply_uci_set || fail 'unparsed candidate accepted'
cmp -s "$DA_UCI" "$DA_WORK/before.1" || fail 'parse failure changed config'

reset_case
touch "$work/changes-fail"
! dns_apply_uci_set || fail 'unreadable delta journal accepted'
cmp -s "$DA_UCI" "$DA_WORK/before.1" || fail 'unreadable delta journal changed config'

reset_case
DA_SERVER="bad'quote"
! dns_apply_uci_set || fail 'unsafe DNS literal accepted'
cmp -s "$DA_UCI" "$DA_WORK/before.1" || fail 'unsafe DNS literal changed config'
DA_SERVER=9.9.9.9

reset_case
printf "config settings 'settings'\n" >> "$DA_UCI"
cp "$DA_UCI" "$DA_WORK/before.1"
sha256sum "$DA_UCI" | awk '{print $1}' > "$DA_WORK/before.1.sha"
! dns_apply_uci_set || fail 'duplicate settings accepted'

reset_case
dns_apply_uci_set || fail 'rollback fixture write'
printf "podkop.settings.dns_server='later draft'\n" > "$fixture_pending"
cp "$fixture_pending" "$work/pending.expected"
dns_apply_uci_clear_staged || fail 'safe no-staging cleanup failed'
dns_apply_uci_restore "$DA_WORK/before.1" "$DA_UCI" || fail 'owned committed write not restored'
cmp -s "$DA_UCI" "$DA_WORK/before.1" || fail 'restore bytes differ'
cmp -s "$fixture_pending" "$work/pending.expected" || fail 'rollback discarded later DNS draft'
[ ! -s "$mutations" ] || fail 'rollback reverted shared UCI delta'

reset_case
dns_apply_uci_set || fail 'external rollback fixture write'
printf "# external saved edit\n" >> "$DA_UCI"
cp "$DA_UCI" "$work/external"
! dns_apply_uci_restore "$DA_WORK/before.1" "$DA_UCI" || fail 'rollback accepted foreign committed edit'
cmp -s "$DA_UCI" "$work/external" || fail 'rollback overwrote foreign edit'
echo 'PASS: DNS-only atomic write, late-draft and committed CAS guards, non-destructive rollback'

reset_case
DA_SECONDARY_TYPE=dot; DA_SECONDARY_SERVER=dns.google
DA_SECONDARY_BOOT_TYPE=udp; DA_SECONDARY_BOOT_SERVER=1.0.0.1
dns_apply_uci_set || fail 'atomic dual-pair write'
grep -q "option secondary_dns_server 'dns.google'" "$DA_UCI" || fail 'reserve missing'
grep -q "option secondary_dns_enabled '1'" "$DA_UCI" || fail 'reserve not enabled'
! grep -q "option dns_failover_enabled '1'" "$DA_UCI" || fail 'failover silently enabled'
dns_apply_uci_restore "$DA_WORK/before.1" "$DA_UCI" || fail 'dual-pair restore'
cmp "$DA_UCI" "$DA_WORK/before.1" || fail 'reserve not rolled back with primary'
unset DA_SECONDARY_TYPE DA_SECONDARY_SERVER DA_SECONDARY_BOOT_TYPE DA_SECONDARY_BOOT_SERVER
echo 'PASS: primary and reserve committed and restored in one transaction; failover policy untouched'

