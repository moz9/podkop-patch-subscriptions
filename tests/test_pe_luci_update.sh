#!/bin/sh
# Catches changed payload mapping, unpinned/tampered code, identity bypass,
# unverified receipts and confirmation despite frozen-graph/UI drift.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
adapter="$root/openwrt/podkop-pe-luci-update"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$adapter" ] || fail 'PE24 LuCI files-only adapter is missing'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
set -- --library
. "$adapter"
# Pin the independently reviewed RouterDesk protocol without requiring its
# separate repository to be checked out next to this public release.
for entry in \
    b478c7604bb0f26bd7650ac512f1c997bc457ab41ef81467b73c0a8ca99f0523:pe-patch-job.sh \
    b9dfce9e4c06c9bf2b626f58620dc1079bb924f92667d4b9c17024557bf14a00:pe-patch-files.sh \
    2e4a54ede15b3af6e02f1b576bc589d5dd4044b7949a6112ac488aef6998c68c:pe-frozen-graph.sh \
    62973f275fc8601c3879a940b0a3b72d713816aecf2993bd2e9ac2e4598e0fed:pe-patch-timeout.sh; do
    [ "$(pl_sha "$root/openwrt/${entry#*:}")" = "${entry%%:*}" ] || fail "changed immutable coordinator: ${entry#*:}"
done
mkdir -p "$tmp/release/openwrt" "$tmp/job/new"
# Complete transport fixture, with independent literal mapping checks below.
for file in runtime-0.7.24/usr/bin/podkop podkop-diagnostic-policy.sh podkop-section-hooks.sh podkop-section-worker.init podkop-dns-failover.init podkop-memdoc-guard dns-main.json dns-bootstrap.json podkop.ru.lmo.base64 main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js dns_benchmark.js podkop-dns-optimizer podkop-dns-benchmark podkop-dns-apply podkop-dns-failover podkop-update-manager podkop-section-runtime podkop-single-runtime runtime-0.7.24/usr/lib/podkop/constants.sh runtime-0.7.24/usr/lib/podkop/helpers.sh runtime-0.7.24/usr/lib/podkop/sing_box_config_facade.sh runtime-0.7.24/usr/lib/podkop/sing_box_config_manager.sh podkop-subscription-sources-upgrade.sh; do
    mkdir -p "$tmp/release/openwrt/$(dirname "$file")"
    case "$file" in
        *.js) printf "'require view.podkop.section';\n";;
        *.json) printf '{}\n';;
        *.base64) printf 'dHJhbnNsYXRpb24=\n';;
        *) printf '#!/bin/sh\n# %s\n\n\n' "$file";;
    esac > "$tmp/release/openwrt/$file"
done
for file in pe-patch-job.sh pe-patch-files.sh pe-frozen-graph.sh pe-patch-timeout.sh; do cp "$root/openwrt/$file" "$tmp/release/openwrt/$file"; done
(cd "$tmp/release" && find openwrt -type f | LC_ALL=C sort | while IFS= read -r file; do printf '%s\t%s\n' "$file" "$(sha256sum "$file"|cut -d' ' -f1)"; done) > "$tmp/hashes"
jq -Rn --arg job "$PL_JOB_SHA" --arg files "$PL_FILES_SHA" '[inputs|split("\t")|{key:.[0],value:.[1]}]|from_entries|{schemaVersion:1,channel:"podkop-pe",supportedPodkopVersions:["0.7.24"],recommendedPodkopVersion:"0.7.24",engineVersion:"1.14.2-pdk-r14",patchVersion:"20261028-pe-v41",releaseStatus:"released",pinnedCommit:"0123456789abcdef0123456789abcdef01234567",routerdeskPatch:{schemaVersion:1,mode:"files-only",coordinatorSha256:$job,filesSha256:$files,initIntegration:1,luciFilesOnly:1},sha256:.}' < "$tmp/hashes" > "$tmp/manifest"
pl_download() {
    case "$1" in https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/0123456789abcdef0123456789abcdef01234567/openwrt/*) ;;
        *) fail "unpinned transport request: $1";; esac
    path="${1#https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/0123456789abcdef0123456789abcdef01234567/}"
    cp "$tmp/release/$path" "$2"
}
pl_validate_manifest "$tmp/manifest" || fail valid-contract
cp "$tmp/manifest" "$tmp/release/openwrt/update-manifest.json"
mkdir "$tmp/pin"
pl_pin_manifest "$tmp/manifest" "$tmp/pin" || fail pinned-manifest-readback
jq '.patchVersion="20261028-pe-v42"' "$tmp/manifest" > "$tmp/release/openwrt/update-manifest.json"
if pl_pin_manifest "$tmp/manifest" "$tmp/pin"; then fail pinned-manifest-drift; fi
cp "$tmp/manifest" "$tmp/release/openwrt/update-manifest.json"
pl_build "$tmp/manifest" "$tmp/job" || fail payload-build
pl_stage_code "$tmp/manifest" "$tmp/job" || fail immutable-code-stage
(cd "$tmp/job" && sha256sum -c code.sha256) || fail immutable-code-checksums
[ "$(wc -l < "$tmp/job/targets")" = 37 ] || fail payload-count
awk '$2==755&&$3=="usr/bin/podkop"{found++}END{exit(found!=1)}' "$tmp/job/targets" || fail runtime-target
index="$(awk '$3=="usr/bin/podkop"{print $4}' "$tmp/job/targets")"
printf '#!/bin/sh\n# runtime-0.7.24/usr/bin/podkop\n\n# PODKOP_SUBSCRIPTIONS_PATCH_VERSION=20261028-pe-v41\n' > "$tmp/runtime.expected"
cmp "$tmp/runtime.expected" "$tmp/job/new/$index" || fail runtime-transform
index="$(awk '$3=="www/luci-static/resources/view/podkop_patch_20261028_pe_v41/main.js"{print $4}' "$tmp/job/targets")"
printf "'require view.podkop_patch_20261028_pe_v41.section';\n" > "$tmp/view.expected"
cmp "$tmp/view.expected" "$tmp/job/new/$index" || fail namespace-transform
index="$(awk '$3=="usr/lib/lua/luci/i18n/podkop.ru.lmo"{print $4}' "$tmp/job/targets")"
[ "$(cat "$tmp/job/new/$index")" = translation ] || fail translation-decode
for change in '.pinnedCommit="main"' '.routerdeskPatch.luciFilesOnly=0' '.routerdeskPatch.coordinatorSha256=("a"*64)' '.engineVersion="1.13.21-pdk-r11"' '.recommendedPodkopVersion="0.7.23"'; do
    jq "$change" "$tmp/manifest" > "$tmp/bad"
    if pl_validate_manifest "$tmp/bad"; then fail "unsafe contract accepted: $change"; fi
done
printf tampered >> "$tmp/release/openwrt/main.js"
mkdir -p "$tmp/tampered/new"
if pl_build "$tmp/manifest" "$tmp/tampered"; then fail tampered-payload; fi
pl_package_version() { case "$1" in podkop|luci-app-podkop) echo "$base";; podkop-engine) echo "$engine";; esac; }
pl_arch() { echo aarch64_cortex-a53; }
pl_podkop_version() { echo 0.7.24; }
pl_runtime_version() { echo "$runtime_version"; }
base=0.7.24-r1; engine=1.14.2-r14; runtime_version='sing-box version 1.14.2-pdk-r14'
pl_identity || fail correct-identity
base=0.7.23-r1
if pl_identity; then fail wrong-base; fi
base=0.7.24-r1; engine=1.13.21-r11
if pl_identity; then fail wrong-package-engine; fi
engine=1.14.2-r14; runtime_version='sing-box version 1.13.21-pdk-r11'
if pl_identity; then fail wrong-running-engine; fi
# Real bounded downloader, fake curl transport: oversized chunked bodies can
# never consume the persistent rollback reserve regardless of curl version.
(
    eval "$(sed -n '/^pl_download() {$/,/^}$/p' "$adapter")"
    curl() { head -c 2097252 /dev/zero; }
    if pl_download https://fixture.invalid "$tmp/oversized"; then fail oversized-download; fi
    [ "$(wc -c < "$tmp/oversized")" -le 2097153 ] || fail unbounded-download
)
# Actual transaction files and actual graph closure; replace only platform IO.
[ "$(id -u)" = 0 ] || fail 'run this isolated filesystem fixture as root (frozen graph ownership contract)'
. "$root/openwrt/pe-patch-files.sh"
. "$root/openwrt/pe-patch-job.sh"
. "$root/openwrt/pe-frozen-graph.sh"
PT_ROOT="$tmp/root"; PT_JOB="$tmp/transaction"
mkdir -p "$PT_ROOT/usr/bin" "$PT_ROOT/etc/sing-box" "$PT_JOB/new"
cp "$root/openwrt/pe-patch-files.sh" "$PT_JOB/files.sh"
printf old > "$PT_ROOT/usr/bin/podkop"
printf new > "$PT_JOB/new/0"
printf '{}\n' > "$PT_ROOT/etc/sing-box/config.json"
printf '%s 755 usr/bin/podkop 0\n' "$(sha256sum "$PT_JOB/new/0"|cut -d' ' -f1)" > "$PT_JOB/targets"
pt_capture
pl_receipt "$PT_JOB" || fail local-archive-receipt
[ -s "$PT_JOB/pc-receipt" ] && [ -s "$PT_JOB/local-receipt.json" ] || fail receipt-absent
jq -e '.backupLocation=="router-local" and .pcBackupVerified==false' "$PT_JOB/local-receipt.json" >/dev/null || fail receipt-scope
printf '/etc/sing-box/config.json\n' > "$PT_JOB/graph.roots"
pe_graph_capture "$PT_ROOT" "$PT_JOB" "$PT_JOB/graph.roots"
pj_health() { return 0; }; pj_ui_reload() { return 0; }; pj_disarm() { return 0; }; pj_unlock() { return 0; }
pl_job() { case "$2" in status) printf 'PATCH=%s\n' "$(cat "$1/state")";; confirm) pj_confirm;; rollback) pj_rollback explicit;; esac; }
pl_ui_check() { return "$ui_status"; }; pl_dns_check() { return 0; }
pl_graph_check() { pe_graph_unchanged "$PT_ROOT" "$1"; }
ui_status=0; pt_install; pj_state awaiting-confirmation
pl_follow "$PT_JOB" || fail healthy-confirm
[ "$(cat "$PT_JOB/state")" = confirmed ] || fail confirmation-missing
pt_restore; pt_install; pj_state awaiting-confirmation
printf ' ' >> "$PT_ROOT/etc/sing-box/config.json"
if pl_follow "$PT_JOB"; then fail graph-drift-confirmed; fi
[ "$(cat "$PT_JOB/state")" = rolled-back ] && [ "$(cat "$PT_ROOT/usr/bin/podkop")" = old ] || fail graph-drift-rollback
printf '{}\n' > "$PT_ROOT/etc/sing-box/config.json"
ui_status=1; pt_install; pj_state awaiting-confirmation
if pl_follow "$PT_JOB"; then fail unavailable-ui-confirmed; fi
[ "$(cat "$PT_ROOT/usr/bin/podkop")" = old ] || fail UI-rollback-bytes
printf corrupt >> "$PT_JOB/backup.tar"
if pl_receipt "$PT_JOB"; then fail corrupt-backup-receipt; fi
echo 'PASS: PE24 pinned payload, exact mapping, tamper/identity refusal, local receipt, graph/UI drift rollback'
