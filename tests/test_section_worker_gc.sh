#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$work/bin" "$work/state"
printf '#!/bin/sh\nprintf "131072\\n"\n' > "$work/bin/awk"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sing-box"
chmod 700 "$work/bin/"*
PATH="$work/bin:$PATH"; export PATH
PODKOP_SECTION_ROOT="$work/state"; PODKOP_SECTION_SING_BOX="$work/bin/sing-box"
export PODKOP_SECTION_ROOT PODKOP_SECTION_SING_BOX
. "$repo/openwrt/podkop-section-worker.init"
uci() { printf '%s\n' "$enabled_section"; }
procd_open_instance() { recorded_section="${fixture_section:-$1}"; }
procd_set_param() { printf '%s:%s\n' "$recorded_section" "$*" >> "$work/calls"; }
procd_close_instance() { :; }
original_gogc="${GOGC-unset}"
fixture_section=''
if command -v emit_workers >/dev/null; then
  enabled_section=main
  printf '%s\n' '{"version":2,"sections":[{"section":"main","port":19160,"api_port":19163},{"section":"GEOBLOCK","port":19161,"api_port":19164}]}' > "$work/state/metadata.json"
  for section in main GEOBLOCK; do
    case "$section" in main) port=19160; api=19163;; *) port=19161; api=19164;; esac
    mkdir -p "$work/state/workers/$section"
    jq -n --arg s "$section" --argjson p "$port" --argjson a "$api" '{section:$s,port:$p,api_port:$a}' > "$work/state/workers/$section/metadata.json"
    jq -n --arg s "$section" --argjson p "$port" --arg a "127.0.0.1:$api" '{inbounds:[{type:"mixed",tag:"section-in",listen:"127.0.0.1",listen_port:$p}],experimental:{clash_api:{external_controller:$a}},route:{final:($s+"-out"),auto_detect_interface:true,default_mark:2097152}}' > "$work/state/workers/$section/worker.json"
  done
  start_service || fail 'PE worker admission failed'
else
  for fixture_section in main GEOBLOCK; do
    enabled_section="$fixture_section"
    jq -n --arg s "$fixture_section" '{section:$s,port:19160,api_port:19163}' > "$work/state/metadata.json"
    printf '%s\n' '{"inbounds":[{"type":"socks","tag":"section-in","listen":"127.0.0.1","listen_port":19160}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:19163"}},"route":{"auto_detect_interface":true}}' > "$work/state/worker.json"
    start_service || fail 'legacy worker admission failed'
  done
fi
grep -Fxq 'main:env GOGC=25' "$work/calls" || fail 'main worker missing private GOGC=25'
[ "$(grep -c ':env ' "$work/calls")" -eq 1 ] || fail 'peer worker environment changed'
! grep -q 'GOMEMLIMIT' "$work/calls" || fail 'worker memory cap introduced'
[ "${GOGC-unset}" = "$original_gogc" ] || fail 'GOGC leaked into caller environment'
grep -q '^GEOBLOCK:command ' "$work/calls" || fail 'peer worker was omitted'
echo 'PASS: GOGC=25 is private to main worker; peer and caller environments unchanged'
before_calls="$(wc -l < "$work/calls")"
printf 'single\n' > "$work/state/runtime-mode"
start_service || fail 'single mode start guard'
if command -v reload_service >/dev/null; then
  procd_open_service() { fail 'single reload opened a split service update'; }
  procd_close_service() { :; }
  initscript="$repo/openwrt/podkop-section-worker.init"
  reload_service || fail 'single mode reload guard'
else
  # Legacy rc.common reload falls back to restarting start_service.
  start_service || fail 'legacy single reload/start guard'
fi
[ "$(wc -l < "$work/calls")" = "$before_calls" ] || fail 'single mode emitted worker instance'
rm "$work/state/runtime-mode"
start_service || fail 'split mode rollback admission changed'
[ "$(wc -l < "$work/calls")" -gt "$before_calls" ] || fail 'split rollback did not emit workers'
echo 'PASS: single mode suppresses worker start/reload; split rollback unchanged'

