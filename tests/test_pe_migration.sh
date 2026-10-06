#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$repo/m" ] || fail 'migration entrypoint is missing'
sed '/^main "\$@"$/d' "$repo/m" > "$tmp/library"
. "$tmp/library"
ROOT=''
command -v archive_root >/dev/null || fail 'production root archive helper missing'
[ "$(archive_root)" = / ] || fail 'empty production prefix must archive from /'
ROOT="$tmp"
[ "$(archive_root)" = "$tmp" ] || fail 'test filesystem root must be preserved'
if grep -q 'tar -C "\$ROOT"' "$repo/m"; then fail 'archive still uses empty production root prefix'; fi
if grep -q -- '--exclude' "$repo/m"; then fail 'router BusyBox tar lacks GNU exclude option'; fi
tar() {
    for arg do case "$arg" in --exclude*) return 92 ;; esac; done
    command tar "$@"
}
new_case() {
    case_dir="$tmp/$1"; mkdir -p "$case_dir"
    ROOT="$case_dir/root"; mkdir -p "$ROOT/etc/config" "$ROOT/etc/podkop/subscriptions" "$ROOT/etc/init.d" "$ROOT/usr/bin" "$ROOT/usr/lib/podkop" "$ROOT/root" "$ROOT/tmp" "$ROOT/var/lib/zerotier-one"
    printf "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.4'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$ROOT/etc/openwrt_release"
    for p in podkop network firewall dhcp byedpi warp zerotier; do printf 'private-%s\n' "$p" > "$ROOT/etc/config/$p"; done
    printf 'private-subscription\n' > "$ROOT/etc/podkop/subscriptions/source"
    printf 'private-identity\n' > "$ROOT/var/lib/zerotier-one/identity.secret"
    printf '#!/bin/sh\nprintf old-runtime\\n\n' > "$ROOT/usr/bin/podkop"
    printf '#!/bin/sh\ncase "$1" in version) printf "sing-box version 1.13.21-pdk-r11\\nFeatures: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link\\n" ;; check) exit 0 ;; esac\n' > "$ROOT/usr/bin/sing-box"
    chmod +x "$ROOT/usr/bin/sing-box"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/init-events"\n' "$case_dir" > "$ROOT/etc/init.d/podkop"
    chmod +x "$ROOT/etc/init.d/podkop" "$ROOT/usr/bin/podkop"
    printf 'podkop 0.7.22-r1\nluci-app-podkop 0.7.22-r1\nsing-box 1.12.17-r1\nzerotier 1.16-r1\n' > "$case_dir/packages"
    : > "$case_dir/events"
    PENDING=; BAD_HASH=0; PACKAGE_FAIL=0; PATCH_FAIL=0; SPACE=1000000; FAIL_ROLLBACK=0; NO_OLD=0; BAD_PLAN=0; UNRELATED_CHANGE=0; APPROVED_FALLBACK=0; STOCK_CHECK_FAIL=0; ACTIVE_SUB=0; HEALTH_FAIL=0; BAD_ROLLBACK_PLAN=0; DNS_WAS_RUNNING=false
    ENGINE_HASH=$(printf 'engine\n' | sha256sum | awk '{print $1}')
    PODKOP_HASH=$(printf 'podkop\n' | sha256sum | awk '{print $1}')
    LUCI_HASH=$(printf 'luci\n' | sha256sum | awk '{print $1}')
    STOCK_HASH=$(printf 'stock\n' | sha256sum | awk '{print $1}')
    OLD_PODKOP_HASH=$(printf 'oldpodkop\n' | sha256sum | awk '{print $1}')
    OLD_LUCI_HASH=$(printf 'oldluci\n' | sha256sum | awk '{print $1}')
    mkdir -p "$ROOT/etc/sing-box"; printf '{}\n' > "$ROOT/etc/sing-box/config.json"
    mkdir -p "$ROOT/etc/apk"; printf 'podkop\nluci-app-podkop\nsing-box\n' > "$ROOT/etc/apk/world"
}
id() { printf '0\n'; }
# Wall-clock waiting is an appliance boundary; keep readiness state/polls real.
sleep() { :; }
uci() { case "$1 ${2:-}" in 'changes ') printf '%s' "$PENDING" ;; '-q show') [ "$ACTIVE_SUB" = 0 ] || printf "podkop.main.proxy_config_type='subscription_urltest'\n" ;; *) return 91 ;; esac; }
ubus() { case "$*" in *podkop-dns-failover*) printf '{"podkop-dns-failover":{"instances":{"main":{"running":%s,"pid":%s}}}}\n' "$DNS_WAS_RUNNING" "$$" ;; *) printf '{"sing-box":{"instances":{"main":{"running":%s,"pid":%s}}}}\n' "$(if [ "$HEALTH_FAIL" = 0 ]; then printf true; else printf false; fi)" "$$" ;; esac; }
apk() {
    printf 'apk %s\n' "$*" >> "$case_dir/events"
    case "$1" in
      --print-arch) printf 'aarch64\n' ;;
      list) cat "$case_dir/packages" ;;
      info) [ "$2" != -e ] || grep -q "^$3 " "$case_dir/packages" ;;
      fetch) [ "$NO_OLD" = 0 ] || return 1; out=$3; shift 3; for p do printf 'recovery-%s\n' "$p" > "$out/${p%%=*}-${p#*=}.apk"; done ;;
      verify) return 0 ;;
      extract)
        out=$4; mkdir -p "$out/usr/bin"
        printf '#!/bin/sh\ncase "$1" in version) printf "sing-box version 1.13.21\\n" ;; check) exit %s ;; esac\n' "$STOCK_CHECK_FAIL" > "$out/usr/bin/sing-box"
        chmod +x "$out/usr/bin/sing-box" ;;
      add)
        case " $* " in *' --simulate '*) [ "$BAD_PLAN" = 0 ] || printf '(1/5) Purging zerotier (1.16-r1)\n'; if [ "$BAD_ROLLBACK_PLAN" = 1 ] && grep -q '^podkop-engine ' "$case_dir/packages"; then case "$*" in *'/old/'*) printf '(2/3) Purging zerotier (1.16-r1)\n' ;; esac; fi; printf '(1/3) Upgrading podkop (0.7.22-r1 -> 0.7.23-r1)\n'; return 0 ;; esac
        case " $* " in *'/old/'*) [ "$FAIL_ROLLBACK" = 0 ] || return 1; stock_version=1.12.17-r1; [ "$APPROVED_FALLBACK" = 0 ] || stock_version=1.13.21-r1; printf 'podkop 0.7.22-r1\nluci-app-podkop 0.7.22-r1\nsing-box %s\nzerotier 1.16-r1\n' "$stock_version" > "$case_dir/packages"; return 0 ;; esac
        printf 'podkop 0.7.23-r1\nluci-app-podkop 0.7.23-r1\npodkop-engine 1.13.21-r11\nzerotier 1.16-r1\n' > "$case_dir/packages"
        printf 'podkop\nluci-app-podkop\npodkop-engine\n' > "$ROOT/etc/apk/world"
        [ "$UNRELATED_CHANGE" = 0 ] || sed -i '/^zerotier /d' "$case_dir/packages"
        printf 'damaged\n' > "$ROOT/etc/config/podkop"
        [ "$PACKAGE_FAIL" = 0 ] ;;
      del) return 0 ;;
      *) return 92 ;;
    esac
}
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/test 2000000 1 %s 1%% /\n' "$SPACE"; }
download() {
    printf 'download %s\n' "$1" >> "$case_dir/events"
    case "$1" in
      */commits/podkop-pe\?t=*) printf '{"sha":"1111111111111111111111111111111111111111"}\n' > "$2" ;;
      */openwrt/update-manifest.json)
        h=$(sha256sum "$case_dir/installer" | awk '{print $1}')
        printf '{"schemaVersion":1,"channel":"podkop-pe","patchVersion":"test-v1","sha256":{"i":"%s","m":"%s","openwrt/asset":"%s"}}\n' "$h" "$(sha256sum "$repo/m" | awk '{print $1}')" "$(printf 'asset\n' | sha256sum | awk '{print $1}')" > "$2" ;;
      */i) cp "$case_dir/installer" "$2" ;;
      */m) cp "$repo/m" "$2" ;;
      */openwrt/asset) if [ "$BAD_HASH" = 1 ]; then printf 'bad\n'; else printf 'asset\n'; fi > "$2" ;;
      *podkop-engine*.apk) printf 'engine\n' > "$2" ;;
      */podkop-0.7.23-r1.apk) printf 'podkop\n' > "$2" ;;
      */luci-app-podkop-0.7.23-r1.apk) printf 'luci\n' > "$2" ;;
      */sing-box-1.13.21-r1.apk) [ "$APPROVED_FALLBACK" = 1 ] || return 1; printf 'stock\n' > "$2" ;;
      */podkop-0.7.22-r1.apk) [ "$APPROVED_FALLBACK" = 1 ] || return 1; printf 'oldpodkop\n' > "$2" ;;
      */luci-app-podkop-0.7.22-r1.apk) [ "$APPROVED_FALLBACK" = 1 ] || return 1; printf 'oldluci\n' > "$2" ;;
      *) return 93 ;;
    esac
}
prepare_installer() {
    printf '#!/bin/sh\n# PODKOP_PATCH_DEFER_SERVICE_START\nprintf "patched\\n" >> "%s/events"\nprintf "#!/bin/sh\\n# PODKOP_SUBSCRIPTIONS_PATCH_VERSION=test-v1\\nexit 0\\n" > "%s/usr/bin/podkop"\nexit %s\n' "$case_dir" "$ROOT" "$PATCH_FAIL" > "$case_dir/installer"
}
run_case() { prepare_installer; (main "$@") > "$case_dir/output" 2>&1; }
preserved() {
    for p in podkop network firewall dhcp byedpi warp zerotier; do [ "$(cat "$ROOT/etc/config/$p")" = "private-$p" ] || fail "config $p changed"; done
    [ "$(cat "$ROOT/etc/podkop/subscriptions/source")" = private-subscription ] || fail 'subscriptions changed'
    [ "$(cat "$ROOT/var/lib/zerotier-one/identity.secret")" = private-identity ] || fail 'ZT identity changed'
}
new_case check; run_case || { cat "$case_dir/output"; fail check; }; preserved
[ ! -e "$case_dir/init-events" ] || fail 'check stopped service'
! grep -E 'apk (del|add .*--no-scripts)' "$case_dir/events" | grep -v -- --simulate >/dev/null || fail 'check changed packages'
[ ! -e "$ROOT/root/podkop-pe-migration" ] || fail 'check created persistent backup'
new_case busy; mkdir "$ROOT/tmp/podkop-subscription-action.lock.d"; if run_case --apply; then fail 'busy accepted'; fi; preserved
new_case pending; PENDING='podkop.main.x=1'; if run_case --apply; then fail 'pending accepted'; fi; preserved
new_case no-space; SPACE=1; if run_case --apply; then fail 'no space accepted'; fi; preserved
new_case bad-hash; BAD_HASH=1; if run_case --apply; then fail 'bad checksum accepted'; fi; [ ! -e "$case_dir/init-events" ] || fail 'hash failure stopped service'; preserved
new_case bad-plan; BAD_PLAN=1; if run_case --apply; then fail 'unrelated package removal plan accepted'; fi; [ ! -e "$case_dir/init-events" ] || fail 'unsafe plan stopped service'
new_case unrelated-package; UNRELATED_CHANGE=1; if run_case --apply; then fail 'unrelated package mutation accepted'; fi
new_case success; run_case --apply || { cat "$case_dir/output"; fail apply; }; preserved
grep -q test-v1 "$ROOT/usr/bin/podkop" || fail 'patched runtime missing'
grep -q 'complete' "$ROOT/root/podkop-pe-migration"/*/status || fail 'complete state missing'
test -f "$ROOT/root/podkop-pe-migration"/*/migration.sh || fail 'self-contained recovery script missing'
grep -q '^stop$' "$case_dir/init-events" || fail 'service not stopped'
n=$(grep -c '^download\|^apk add\|^apk del' "$case_dir/events"); run_case --apply || fail noop; [ "$(grep -c '^download\|^apk add\|^apk del' "$case_dir/events")" -eq "$n" ] || fail 'second apply was not read-only no-op'
new_case partial; PACKAGE_FAIL=1; if run_case --apply; then fail 'partial install accepted'; fi; preserved
grep -q 'rolled-back' "$ROOT/root/podkop-pe-migration"/*/status || fail 'partial install not rolled back'
grep -q old-runtime "$ROOT/usr/bin/podkop" || fail 'old runtime not restored'
new_case patch-fail; PATCH_FAIL=1; if run_case --apply; then fail 'failed patch accepted'; fi; preserved
grep -q 'rolled-back' "$ROOT/root/podkop-pe-migration"/*/status || fail 'failed patch not rolled back'
new_case rollback-fail; PACKAGE_FAIL=1; FAIL_ROLLBACK=1; if run_case --apply; then fail 'failed rollback accepted'; fi
grep -q 'recovery-required' "$ROOT/root/podkop-pe-migration"/*/status || fail 'rollback failure hidden'
! grep -q '^start$' "$case_dir/init-events" || fail 'service started after failed package restore'
new_case no-recovery; NO_OLD=1; run_case --check || { cat "$case_dir/output"; fail 'unavailable old APK should explicitly downgrade recovery level'; }
grep -q 'snapshot-only' "$case_dir/output" || fail 'missing limited-recovery warning'
new_case snapshot-only-failure; NO_OLD=1; PACKAGE_FAIL=1; if run_case --apply; then fail 'partial snapshot-only install accepted'; fi
[ ! -e "$case_dir/init-events" ] || fail 'unrecoverable migration stopped service'
new_case resume; PACKAGE_FAIL=1; FAIL_ROLLBACK=1; if run_case --apply; then fail 'partial apply accepted'; fi
saved_resume=$(find "$ROOT/root/podkop-pe-migration" -mindepth 1 -maxdepth 1 -type d)
PACKAGE_FAIL=0; FAIL_ROLLBACK=0
run_case --resume "$saved_resume" || { cat "$case_dir/output"; fail resume; }
preserved
grep -q 'complete' "$saved_resume/status" || fail 'forward recovery not completed'
new_case tampered-resume; PACKAGE_FAIL=1; FAIL_ROLLBACK=1; if run_case --apply; then fail 'partial apply accepted'; fi
saved_resume=$(find "$ROOT/root/podkop-pe-migration" -mindepth 1 -maxdepth 1 -type d)
printf 'tampered\n' > "$saved_resume/preserve.tar"
PACKAGE_FAIL=0; n=$(grep -c '^apk add' "$case_dir/events")
if run_case --resume "$saved_resume"; then fail 'tampered resume accepted'; fi
[ "$(grep -c '^apk add' "$case_dir/events")" -eq "$n" ] || fail 'tampered resume changed packages'
new_case approved-stock; NO_OLD=1; APPROVED_FALLBACK=1; PACKAGE_FAIL=1; if run_case --apply; then fail 'failed apply accepted'; fi
preserved
grep -q 'rolled-back-stock-newer' "$ROOT/root/podkop-pe-migration"/*/status || fail 'approved stock rollback did not occur'
grep -q 'sing-box 1.13.21-r1' "$case_dir/packages" || fail 'newer stock version not installed'
new_case invalid-stock-config; NO_OLD=1; APPROVED_FALLBACK=1; STOCK_CHECK_FAIL=1
if run_case --apply; then fail 'fallback unable to check old config accepted'; fi
[ ! -e "$case_dir/init-events" ] || fail 'bad fallback config stopped service'
new_case stale-check; mkdir "$ROOT/tmp/podkop-subscription-action.lock.d"; printf '999999 migration 1\n' > "$ROOT/tmp/podkop-subscription-action.lock.d/owner"
if run_case --check; then fail 'check silently cleared stale lock'; fi
[ -f "$ROOT/tmp/podkop-subscription-action.lock.d/owner" ] || fail 'check modified stale lock'
run_case --apply || { cat "$case_dir/output"; fail 'stale apply reclaim'; }
new_case missing-cache; ACTIVE_SUB=1
if run_case --apply; then fail 'active subscription without offline cache accepted'; fi
[ ! -e "$case_dir/init-events" ] || fail 'missing cache stopped service'
new_case service-dead; HEALTH_FAIL=1
if run_case --apply; then fail 'dead engine accepted as successful migration'; fi
grep -q 'recovery-required' "$ROOT/root/podkop-pe-migration"/*/status || fail 'failed service health hidden'
new_case bad-rollback-plan; PACKAGE_FAIL=1; BAD_ROLLBACK_PLAN=1
if run_case --apply; then fail 'bad rollback plan accepted'; fi
grep -q 'recovery-required' "$ROOT/root/podkop-pe-migration"/*/status || fail 'unsafe rollback not marked recovery-required'
grep -q '^podkop-engine$' "$ROOT/etc/apk/world" || fail 'failed rollback plan did not restore current world constraint'
new_case dns-watcher; DNS_WAS_RUNNING=true; PACKAGE_FAIL=1
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/dns-events"\n' "$case_dir" > "$ROOT/etc/init.d/podkop-dns-failover"
chmod +x "$ROOT/etc/init.d/podkop-dns-failover"
if run_case --apply; then fail 'failed apply with DNS watcher accepted'; fi
grep -q '^stop$' "$case_dir/dns-events" || fail 'old DNS watcher not stopped'
grep -q '^start$' "$case_dir/dns-events" || fail 'previous DNS watcher not restored'
new_case manual-rollback; NO_OLD=1; APPROVED_FALLBACK=1
run_case --apply || { cat "$case_dir/output"; fail 'prepare manual rollback'; }
saved_resume=$(find "$ROOT/root/podkop-pe-migration" -mindepth 1 -maxdepth 1 -type d)
run_case --rollback "$saved_resume" || { cat "$case_dir/output"; fail 'manual rollback'; }
preserved
grep -q 'rolled-back-stock-newer' "$saved_resume/status" || fail 'manual rollback checkpoint missing'
printf 'PASS: PE migration read-only gates, preservation, offline staging, rollback truth and idempotency\n'
