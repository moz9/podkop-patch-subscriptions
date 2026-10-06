#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# The preserved historical runtime remains checked, but PE must not advertise
# compatibility with its unsupported 0.7.22 installation generation.
installer_target="$(sed -n 's/^PODKOP_PATCH_TARGET_PODKOP_VERSION=//p' i)"
installer_supported="$(sed -n 's/^PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS=//p' i)"
manifest_target="$(jq -r '.recommendedPodkopVersion' openwrt/update-manifest.json)"
manifest_supported="$(jq -r '.supportedPodkopVersions | join(" ")' openwrt/update-manifest.json)"

[ "$installer_target" = 0.7.23 ] || fail "PE installer target is $installer_target instead of 0.7.23"
[ "$manifest_target" = 0.7.23 ] || fail "PE manifest target is $manifest_target instead of 0.7.23"
[ "$installer_supported" = 0.7.23 ] || fail 'PE installer advertises unsupported legacy versions'
[ "$manifest_supported" = 0.7.23 ] || fail 'PE manifest advertises unsupported legacy versions'

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

if grep -Eq '^RUNTIME_0722_|^install_prebuilt_0722_runtime\(' i; then
    fail 'PE installer must not deliver the historical 0.7.22 runtime'
fi

cmp -s i openwrt/install.sh || fail 'i and openwrt/install.sh differ'
sh -n i || fail 'installer syntax is invalid'
sh -n "$runtime" || fail '0.7.22 runtime syntax is invalid'

printf '%s\n' 'PASS: historical 0.7.22 runtime is intact and excluded from PE support'
