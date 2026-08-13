#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
library="$test_root/installer-functions.sh"
asset_tmp="$test_root/assets"
view_root="$test_root/views"
menu_file="$test_root/menu/luci-app-podkop.json"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$asset_tmp" "$(dirname "$menu_file")"

PODKOP_PATCH_LUCI_VIEW_ROOT="$view_root"
PODKOP_PATCH_LUCI_MENU_FILE="$menu_file"
export PODKOP_PATCH_LUCI_VIEW_ROOT PODKOP_PATCH_LUCI_MENU_FILE

sed \
    -e 's/\r$//' \
    -e '/^tmp_dir="$(mktemp -d)"$/,$d' \
    "$repo_root/i" > "$library"

# shellcheck disable=SC1090
. "$library"

abort_with_restore() {
    fail_test "$1"
}

tmp_dir="$asset_tmp"
for asset in main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
    cp "$repo_root/openwrt/$asset" "$tmp_dir/$asset"
done

cat > "$menu_file" <<'MENU_EOF'
{
  "admin/services/podkop": {
    "title": "Podkop",
    "order": 42,
    "action": {"type": "view", "path": "podkop/podkop"},
    "depends": {"acl": ["luci-app-podkop"], "uci": {"podkop": true}}
  }
}
MENU_EOF

prepare_versioned_luci_assets || fail_test 'versioned assets were not prepared'

versioned_tmp="$tmp_dir/luci-versioned/$LUCI_MODULE_NAMESPACE"
for asset in podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
    grep -q "require view.$LUCI_MODULE_NAMESPACE.main as main" "$versioned_tmp/$asset" ||
        fail_test "$asset does not import the versioned main module"
done

for dependency in settings section dashboard diagnostic subscriptions; do
    grep -q "require view.$LUCI_MODULE_NAMESPACE.$dependency as $dependency" "$versioned_tmp/podkop.js" ||
        fail_test "podkop.js does not import versioned $dependency"
done

if grep -q 'require view\.podkop\.' "$versioned_tmp"/*.js; then
    fail_test 'a versioned asset still imports the cache-prone podkop namespace'
fi

install_versioned_luci_assets
base_luci_assets_current || fail_test 'unversioned compatibility assets do not verify'
versioned_luci_assets_current || fail_test 'versioned assets or menu do not verify'

[ "$LUCI_VIEW_ROOT" = "$view_root" ] || fail_test 'view-root override was ignored'
[ "$LUCI_MENU_FILE" = "$menu_file" ] || fail_test 'menu-path override was ignored'

for asset in main.js podkop.js section.js subscriptions.js settings.js dashboard.js diagnostic.js; do
    cmp -s "$view_root/podkop/$asset" "$tmp_dir/$asset" ||
        fail_test "unversioned $asset differs from the release asset"
    cmp -s "$view_root/$LUCI_MODULE_NAMESPACE/$asset" "$versioned_tmp/$asset" ||
        fail_test "versioned $asset differs from the prepared asset"
done

jq -e --arg path "$LUCI_MODULE_ENTRY" \
    '.["admin/services/podkop"].action == {"type":"view","path":$path} and
     .["admin/services/podkop"].title == "Podkop" and
     .["admin/services/podkop"].depends.acl == ["luci-app-podkop"]' \
    "$menu_file" >/dev/null || fail_test 'menu was not safely redirected to the versioned entrypoint'

printf '%s\n' '// stale browser-cached module' >> "$view_root/$LUCI_MODULE_NAMESPACE/main.js"
if versioned_luci_assets_current; then
    fail_test 'no-op verification accepted a stale versioned main module'
fi
cp "$versioned_tmp/main.js" "$view_root/$LUCI_MODULE_NAMESPACE/main.js"

jq '.["admin/services/podkop"].action.path = "podkop/podkop"' "$menu_file" > "$test_root/old-menu.json"
cp "$test_root/old-menu.json" "$menu_file"
if versioned_luci_assets_current; then
    fail_test 'no-op verification accepted the cache-prone legacy menu path'
fi

for required in \
    usr/share/luci/menu.d/luci-app-podkop.json \
    etc/rc.d/K10podkop-dns-failover \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/main.js \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/podkop.js \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/section.js \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/subscriptions.js \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/settings.js \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/dashboard.js \
    www/luci-static/resources/view/podkop_patch_20260813_reliability_responsive_v1/diagnostic.js; do
    printf '%s\n' "$RUNTIME_FILES" | grep -Fxq "$required" ||
        fail_test "backup/rollback inventory omits $required"
done

sed -n '/^luci_assets_current() {/,/^}/p' "$repo_root/i" |
    grep -q 'versioned_luci_assets_current' ||
    fail_test 'installer no-op capability check does not require the versioned namespace'

printf '%s\n' 'PASS: LuCI assets use a release-versioned namespace with menu, rollback, and no-op guards'
