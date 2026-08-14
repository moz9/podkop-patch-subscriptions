#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT INT TERM

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
dns_optimizer_google_play_capability="$(normalize openwrt/podkop-dns-optimizer | sed -n 's/^GOOGLE_PLAY_GUARD_CAPABILITY="\([^"]*\)"$/\1/p')"
installer_dns_optimizer_google_play_capability="$(normalize i | sed -n 's/^DNS_OPTIMIZER_GOOGLE_PLAY_GUARD_CAPABILITY="\([^"]*\)"$/\1/p')"
dns_optimizer_chatgpt_capability="$(normalize openwrt/podkop-dns-optimizer | sed -n 's/^CHATGPT_GUARD_CAPABILITY="\([^"]*\)"$/\1/p')"
installer_dns_optimizer_chatgpt_capability="$(normalize i | sed -n 's/^DNS_OPTIMIZER_CHATGPT_GUARD_CAPABILITY="\([^"]*\)"$/\1/p')"
dns_failover_version="$(normalize openwrt/podkop-dns-failover | sed -n 's/^VERSION="\([^"]*\)"$/\1/p')"
installer_dns_failover_version="$(normalize i | sed -n 's/^DNS_FAILOVER_VERSION="\([^"]*\)"$/\1/p')"
manifest_patch="$(jq -r '.patchVersion' openwrt/update-manifest.json)"
manifest_published_at="$(jq -r '.publishedAt' openwrt/update-manifest.json)"
manifest_recommended="$(jq -r '.recommendedPodkopVersion' openwrt/update-manifest.json)"
manifest_supported="$(jq -r '.supportedPodkopVersions | join(" ")' openwrt/update-manifest.json)"
expected_patch_version="20260814-google-play-guard-v3"
expected_dns_optimizer_version="20260814-dns-optimizer-v18"
expected_published_at="2026-08-14T11:28:55+07:00"
expected_google_play_capability="google_play_dns_transport_guard_v1"
expected_chatgpt_capability="chatgpt_dns_transport_guard_v1"

if [ "$manifest_patch" != "$expected_patch_version" ]; then
    printf 'FAIL: release must publish the Google Play guard as %s, got %s\n' \
        "$expected_patch_version" "$manifest_patch" >&2
    exit 1
fi

if [ "$manifest_published_at" != "$expected_published_at" ]; then
    printf 'FAIL: release publication time mismatch: got=%s expected=%s\n' \
        "$manifest_published_at" "$expected_published_at" >&2
    exit 1
fi

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

if [ "$dns_optimizer_version" != "$expected_dns_optimizer_version" ]; then
    printf 'FAIL: DNS optimizer release version mismatch: got=%s expected=%s\n' \
        "$dns_optimizer_version" "$expected_dns_optimizer_version" >&2
    exit 1
fi

if [ -z "$dns_optimizer_google_play_capability" ] ||
    [ "$dns_optimizer_google_play_capability" != "$installer_dns_optimizer_google_play_capability" ] ||
    [ "$dns_optimizer_google_play_capability" != "$expected_google_play_capability" ]; then
    printf 'FAIL: Google Play guard capability mismatch: optimizer=%s installer=%s expected=%s\n' \
        "$dns_optimizer_google_play_capability" \
        "$installer_dns_optimizer_google_play_capability" \
        "$expected_google_play_capability" >&2
    exit 1
fi

if [ -z "$dns_optimizer_chatgpt_capability" ] ||
    [ "$dns_optimizer_chatgpt_capability" != "$installer_dns_optimizer_chatgpt_capability" ] ||
    [ "$dns_optimizer_chatgpt_capability" != "$expected_chatgpt_capability" ]; then
    printf 'FAIL: ChatGPT/OpenAI guard capability mismatch: optimizer=%s installer=%s expected=%s\n' \
        "$dns_optimizer_chatgpt_capability" \
        "$installer_dns_optimizer_chatgpt_capability" \
        "$expected_chatgpt_capability" >&2
    exit 1
fi

sed -n '/^dns_optimizer_has_google_play_guard() {/,/^}/p' i |
    grep -q 'CHATGPT_GUARD_CAPABILITY.*DNS_OPTIMIZER_CHATGPT_GUARD_CAPABILITY' || {
        printf '%s\n' 'FAIL: installer capability predicate omits the ChatGPT/OpenAI guard marker' >&2
        exit 1
    }

sed -n '/^dns_optimizer_has_google_play_guard() {/,/^}/p' i |
    grep -q '^[[:space:]]*grep .*validate_chatgpt_transport' || {
        printf '%s\n' 'FAIL: installer capability predicate omits validate_chatgpt_transport' >&2
        exit 1
    }

sed -n '/^dns_optimizer_has_google_play_guard() {/,/^}/p' i |
    grep -Fq 'https://auth.openai.com/.well-known/openid-configuration' || {
        printf '%s\n' 'FAIL: installer capability predicate omits the exact ChatGPT auth OIDC endpoint' >&2
        exit 1
    }

guard_library="$test_root/dns-optimizer-guard.sh"
partial_optimizer="$test_root/partial-v18-optimizer"
sed -n '/^dns_optimizer_has_google_play_guard() {/,/^}/p' i > "$guard_library"
. "$guard_library"
DNS_OPTIMIZER_GOOGLE_PLAY_GUARD_CAPABILITY="$expected_google_play_capability"
DNS_OPTIMIZER_CHATGPT_GUARD_CAPABILITY="$expected_chatgpt_capability"
cat > "$partial_optimizer" <<EOF
VERSION="$expected_dns_optimizer_version"
GOOGLE_PLAY_GUARD_CAPABILITY="$expected_google_play_capability"
CHATGPT_GUARD_CAPABILITY="$expected_chatgpt_capability"
validate_google_play_transport() {
    return 0
}
validate_chatgpt_transport() {
    return 0
}
EOF
if dns_optimizer_has_google_play_guard "$partial_optimizer"; then
    printf '%s\n' 'FAIL: partially delivered v18 without the auth OIDC endpoint passed the no-op capability predicate' >&2
    exit 1
fi
printf '%s\n' 'https://auth.openai.com/.well-known/openid-configuration' >> "$partial_optimizer"
if ! dns_optimizer_has_google_play_guard "$partial_optimizer"; then
    printf '%s\n' 'FAIL: complete v18 auth OIDC delivery did not satisfy the capability predicate' >&2
    exit 1
fi

sed -n '/^luci_assets_current() {/,/^}/p' i |
    grep -q 'dns_optimizer_has_google_play_guard /usr/bin/podkop-dns-optimizer' || {
        printf '%s\n' 'FAIL: installer no-op verification omits the required transport guard capabilities' >&2
        exit 1
    }

if [ -z "$dns_failover_version" ] || [ "$dns_failover_version" != "$installer_dns_failover_version" ]; then
    printf 'FAIL: DNS failover version mismatch: failover=%s installer=%s\n' \
        "$dns_failover_version" "$installer_dns_failover_version" >&2
    exit 1
fi

printf '%s\n' 'PASS: release metadata is synchronized'
