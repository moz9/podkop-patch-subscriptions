#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
PODKOP_RESTART_WORK=''
trap '[ -z "$PODKOP_RESTART_WORK" ] || rm -rf "$PODKOP_RESTART_WORK"; rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$fixture/etc/config" "$fixture/init.d" "$fixture/bin" "$fixture/rules" "$fixture/section" "$fixture/admitted"
printf 'original-dns\n' > "$fixture/etc/config/dhcp"
printf '{"outbounds":[{"tag":"original-private-node"}]}\n' > "$fixture/runtime.json"
printf 'original-rule\n' > "$fixture/rules/domain.json"
printf 'original-context\n' > "$fixture/section/context.sha256"
printf 'original-admission\n' > "$fixture/admitted/snapshot.json"
printf 'original-table\n' > "$fixture/nft"
printf 'local default dev lo scope host\n' > "$fixture/routes"
printf 'job unrelated\njob /usr/bin/podkop list_update\n' > "$fixture/cron"
printf '0\n' > "$fixture/shutdown"
printf "config settings 'settings'\n\toption shutdown_correctly '1'\n\toption dns_server 'keep-dns'\n" > "$fixture/etc/config/podkop"
printf 'unsaved-filter-choice\n' > "$fixture/drafts"
cat > "$fixture/bin/sing-box" <<'EOF'
#!/bin/sh
exit 0
EOF
for service in sing-box dnsmasq podkop-section-worker; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$1" >> "%s/events"\n' "$service" "$fixture" > "$fixture/init.d/$service"
done
chmod +x "$fixture/bin/sing-box" "$fixture/init.d/"*
PATH="$fixture/bin:$PATH"; export PATH
sed "s|/etc/config/|$fixture/etc/config/|g; s|/etc/init.d/|$fixture/init.d/|g" "$repo/openwrt/podkop-service-snapshot.sh" > "$fixture/helper"
. "$fixture/helper"
PODKOP_SECTION_ROOT="$fixture/section"
TMP_RULESET_FOLDER="$fixture/rules"
NFT_TABLE_NAME=podkop; NFT_FAKEIP_MARK=0x00100000; RT_TABLE_NAME=podkop
config_get() { eval "$1=\"\$fixture/runtime.json\""; }
subscription_services_snapshot_dir() { printf '%s/admitted\n' "$fixture"; }
subscription_sing_box_pid() { echo 123; }
subscription_sing_box_reload_ready() { return 0; }
podkop_section_enabled() { return 1; }
log() { :; }
uci() {
  case "$1" in
    -q) cat "$fixture/shutdown";;
    set) printf '%s\n' "${2#*=}" > "$fixture/shutdown";;
    commit) fail 'rollback must not commit unrelated UCI drafts';;
    *) return 1;;
  esac
}
nft() {
  case "$1" in
    -s|list) cat "$fixture/nft";;
    -f) sed '/^delete table /d' "$2" > "$fixture/nft";;
    *) return 1;;
  esac
}
ip() {
  case "$*" in
    '-4 route show table podkop') cat "$fixture/routes";;
    '-4 rule show') echo '105: from all fwmark 0x100000/0x100000 lookup podkop';;
    '-4 route flush table podkop') : > "$fixture/routes";;
    '-4 route add table podkop '*) shift 5; printf '%s\n' "$*" >> "$fixture/routes";;
    *) return 1;;
  esac
}
crontab() { if [ "$1" = -l ]; then cat "$fixture/cron"; else cat > "$fixture/cron.new"; mv "$fixture/cron.new" "$fixture/cron"; fi; }
subscription_restart_checkpoint_create || fail 'checkpoint capture failed'
saved="$PODKOP_RESTART_WORK"
printf 'new-unadmitted-runtime\n' > "$fixture/runtime.json"
printf 'dns-bypass\n' > "$fixture/etc/config/dhcp"
printf 'new-table\n' > "$fixture/nft"
printf 'new-rules\n' > "$fixture/rules/domain.json"
printf 'new-admission\n' > "$fixture/admitted/snapshot.json"
printf 'job unrelated\njob added-by-another-service\njob /usr/bin/podkop list_update new\n' > "$fixture/cron"
printf '1\n' > "$fixture/shutdown"
subscription_restart_checkpoint_restore || fail 'checkpoint restore failed'
grep -Fq original-private-node "$fixture/runtime.json" || fail 'working nodes lost'
grep -Fxq original-dns "$fixture/etc/config/dhcp" || fail 'DNS forwarding lost'
grep -Fxq original-rule "$fixture/rules/domain.json" || fail 'local rules lost'
grep -Fxq original-admission "$fixture/admitted/snapshot.json" || fail 'admission advanced on failure'
grep -Fxq original-context "$fixture/section/context.sha256" || fail 'context advanced on failure'
grep -Fxq original-table "$fixture/nft" || fail 'Podkop table not restored'
grep -Fxq 'job added-by-another-service' "$fixture/cron" || fail 'unrelated cron lost'
grep -Fxq 'job /usr/bin/podkop list_update' "$fixture/cron" || fail 'original cron lost'
grep -Fq "option shutdown_correctly '0'" "$fixture/etc/config/podkop" || fail 'shutdown flag not restored'
grep -Fq "option dns_server 'keep-dns'" "$fixture/etc/config/podkop" || fail 'desired DNS changed'
grep -Fxq unsaved-filter-choice "$fixture/drafts" || fail 'draft was changed'
grep -Fxq 'dnsmasq restart' "$fixture/events" || fail 'DNS daemon did not reload restored configuration'
subscription_restart_checkpoint_discard
[ ! -e "$saved" ] || fail 'success leaked checkpoint'
ln -s "$fixture/runtime.json" "$fixture/rules/foreign.json"
! subscription_restart_checkpoint_create || fail 'symlink was archived'
subscription_restart_checkpoint_discard
echo 'PASS: real checkpoint restores graph, rules, admission, DNS, own table and cron; rejects symlinks'
