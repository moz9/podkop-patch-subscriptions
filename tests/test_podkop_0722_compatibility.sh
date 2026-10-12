#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

installer_target="$(sed -n 's/^PODKOP_PATCH_TARGET_PODKOP_VERSION="${PODKOP_PATCH_TARGET_PODKOP_VERSION:-\([^"]*\)}"$/\1/p' i)"
installer_supported="$(sed -n 's/^PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS="${PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS:-\([^"]*\)}"$/\1/p' i)"
manifest_target="$(jq -r '.recommendedPodkopVersion' openwrt/update-manifest.json)"
manifest_supported="$(jq -r '.supportedPodkopVersions | join(" ")' openwrt/update-manifest.json)"

[ "$installer_target" = 0.7.22 ] || fail "installer target is $installer_target instead of 0.7.22"
[ "$manifest_target" = 0.7.22 ] || fail "manifest target is $manifest_target instead of 0.7.22"
printf '%s\n' "$installer_supported" | tr ' ' '\n' | grep -Fxq 0.7.22 || fail 'installer does not support 0.7.22'
printf '%s\n' "$manifest_supported" | tr ' ' '\n' | grep -Fxq 0.7.22 || fail 'manifest does not support 0.7.22'

runtime='openwrt/runtime-0.7.22/usr/bin/podkop'
runtime_js='openwrt/runtime-0.7.22/www/luci-static/resources/view/podkop/podkop.js'
[ -s "$runtime" ] || fail '0.7.22 backend runtime is missing'
[ -s "$runtime_js" ] || fail '0.7.22 LuCI entry runtime is missing'

grep -Fq 'is_min_package_version "$version" "1.12.4"' "$runtime" ||
    fail '0.7.22 runtime lost the upstream sing-box version-check fix'
grep -Fq 'PODKOP_SUBSCRIPTIONS_PATCH_VERSION=' "$runtime" ||
    fail '0.7.22 runtime does not contain the subscription patch marker'
grep -Fq 'subscription_apply_v2' "$runtime" ||
    fail '0.7.22 runtime does not contain the current subscription apply backend'

grep -Fq 'RUNTIME_0722_PODKOP_FILE="runtime-0.7.22/usr/bin/podkop"' i ||
    fail 'installer does not declare the 0.7.22 backend runtime'
grep -Fq 'RUNTIME_0722_PODKOP_JS_FILE="runtime-0.7.22/www/luci-static/resources/view/podkop/podkop.js"' i ||
    fail 'installer does not declare the 0.7.22 LuCI runtime'
grep -Fq 'install_prebuilt_0722_runtime' i ||
    fail 'installer does not have a dedicated 0.7.22 runtime path'

cmp -s i openwrt/install.sh || fail 'i and openwrt/install.sh differ'
sh -n i || fail 'installer syntax is invalid'
sh -n "$runtime" || fail '0.7.22 runtime syntax is invalid'

printf '%s\n' 'PASS: Podkop 0.7.22 has a dedicated compatible runtime and release metadata'
