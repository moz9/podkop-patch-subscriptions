#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

normalize() {
    sed 's/\r$//' "$1"
}

assert_lf_only() {
    file="$1"
    carriage_return="$(printf '\r')"

    if grep -q "$carriage_return" "$file"; then
        printf 'FAIL: router executable contains CRLF line endings: %s\n' "$file" >&2
        exit 1
    fi
}

for router_executable in \
    i \
    openwrt/install.sh \
    openwrt/podkop-dns-failover \
    openwrt/podkop-dns-failover.init \
    openwrt/podkop-dns-failover-upgrade.sh \
    openwrt/podkop-dns-optimizer \
    openwrt/podkop-subscription-apply-v2-upgrade.sh \
    openwrt/podkop-update-manager \
    openwrt/runtime-0.7.20/usr/bin/podkop
do
    assert_lf_only "$router_executable"
done

if ! cmp -s i openwrt/install.sh; then
    printf '%s\n' 'FAIL: i and openwrt/install.sh must remain byte-identical' >&2
    exit 1
fi

manager_version="$(normalize openwrt/podkop-update-manager | sed -n 's/^VERSION="\([^"]*\)"$/\1/p')"
installer_manager_version="$(normalize i | sed -n 's/^UPDATE_MANAGER_VERSION="\([^"]*\)"$/\1/p')"
install_marker="$(normalize i | sed -n 's/^INSTALL_MARKER="PODKOP_SUBSCRIPTIONS_PATCH_VERSION=\([^"]*\)"$/\1/p')"
luci_module_namespace="$(normalize i | sed -n 's/^LUCI_MODULE_NAMESPACE="\([^"]*\)"$/\1/p')"
installer_target="$(normalize i | sed -n 's/^PODKOP_PATCH_TARGET_PODKOP_VERSION="${PODKOP_PATCH_TARGET_PODKOP_VERSION:-\([^"]*\)}"$/\1/p')"
installer_supported="$(normalize i | sed -n 's/^PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS="${PODKOP_PATCH_SUPPORTED_PODKOP_VERSIONS:-\([^"]*\)}"$/\1/p')"
dns_optimizer_version="$(normalize openwrt/podkop-dns-optimizer | sed -n 's/^VERSION="\([^"]*\)"$/\1/p')"
installer_dns_optimizer_version="$(normalize i | sed -n 's/^DNS_OPTIMIZER_VERSION="\([^"]*\)"$/\1/p')"
dns_failover_version="$(normalize openwrt/podkop-dns-failover | sed -n 's/^VERSION="\([^"]*\)"$/\1/p')"
installer_dns_failover_version="$(normalize i | sed -n 's/^DNS_FAILOVER_VERSION="\([^"]*\)"$/\1/p')"
manifest_patch="$(jq -r '.patchVersion' openwrt/update-manifest.json)"
manifest_recommended="$(jq -r '.recommendedPodkopVersion' openwrt/update-manifest.json)"
manifest_supported="$(jq -r '.supportedPodkopVersions | join(" ")' openwrt/update-manifest.json)"

if [ -z "$manager_version" ] || [ "$manager_version" != "$installer_manager_version" ]; then
    printf 'FAIL: update manager version mismatch: manager=%s installer=%s\n' \
        "$manager_version" "$installer_manager_version" >&2
    exit 1
fi

if [ -z "$install_marker" ] || [ "$install_marker" != "$manifest_patch" ]; then
    printf 'FAIL: patch version mismatch: marker=%s manifest=%s\n' \
        "$install_marker" "$manifest_patch" >&2
    exit 1
fi

expected_luci_namespace="podkop_patch_$(printf '%s' "$install_marker" | tr '-' '_')"
if [ -z "$luci_module_namespace" ] || [ "$luci_module_namespace" != "$expected_luci_namespace" ]; then
    printf 'FAIL: LuCI module namespace is not release-versioned: namespace=%s expected=%s\n' \
        "$luci_module_namespace" "$expected_luci_namespace" >&2
    exit 1
fi

if [ -z "$installer_target" ] || [ "$installer_target" != "$manifest_recommended" ]; then
    printf 'FAIL: target Podkop version mismatch: installer=%s manifest=%s\n' \
        "$installer_target" "$manifest_recommended" >&2
    exit 1
fi

if [ -z "$installer_supported" ] || [ "$installer_supported" != "$manifest_supported" ]; then
    printf 'FAIL: supported Podkop versions mismatch: installer=%s manifest=%s\n' \
        "$installer_supported" "$manifest_supported" >&2
    exit 1
fi

if [ -z "$dns_optimizer_version" ] || [ "$dns_optimizer_version" != "$installer_dns_optimizer_version" ]; then
    printf 'FAIL: DNS optimizer version mismatch: optimizer=%s installer=%s\n' \
        "$dns_optimizer_version" "$installer_dns_optimizer_version" >&2
    exit 1
fi

if [ -z "$dns_failover_version" ] || [ "$dns_failover_version" != "$installer_dns_failover_version" ]; then
    printf 'FAIL: DNS failover version mismatch: failover=%s installer=%s\n' \
        "$dns_failover_version" "$installer_dns_failover_version" >&2
    exit 1
fi

printf '%s\n' 'PASS: release metadata is synchronized'
