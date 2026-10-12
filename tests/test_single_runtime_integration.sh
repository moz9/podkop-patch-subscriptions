#!/bin/sh
set -eu
tree="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for runtime in "$tree"/openwrt/runtime-*/usr/bin/podkop; do
  grep -q podkop_section_bootstrap "$runtime" || continue
  sed -n '/^get_subscription_operation_status() {/,/^}/p' "$runtime" > "$tmp/status.sh"
  cat > "$tmp/run.sh" <<'EOF'
subscription_runtime_busy() { return 1; }
subscription_reload_pending_file() { echo /nonexistent/pending; }
subscription_pending_sections_json() { echo '[]'; }
podkop_section_enabled() { return 0; }
podkop_section_single_mode() { return 0; }
podkop_section_name() { echo main; }
podkop_section_names() { echo '["main","GEOBLOCK"]'; }
podkop_section_ready() { return 0; }
podkop_section_manager() { echo '{"ready":true,"runtimeMode":"single","sections":[{"section":"main","ready":true,"pid":100},{"section":"GEOBLOCK","ready":true,"pid":100}]}'; }
. "$1"
get_subscription_operation_status
EOF
  sh "$tmp/run.sh" "$tmp/status.sh" | jq -e '.runtimeMode=="single" and .isolatedReady==true and .isolatedSections==["main","GEOBLOCK"]' >/dev/null || { echo "FAIL single operation status: $runtime"; exit 1; }
  sed -n '/^start_main() {/,/^}/p' "$runtime" | grep -q podkop_section_start_workers || { echo "FAIL worker startup integration: $runtime"; exit 1; }
done
echo 'PASS single runtime operation status and startup integration'
