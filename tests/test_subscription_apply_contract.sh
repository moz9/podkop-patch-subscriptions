#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if ! grep -q 'SET_SUBSCRIPTION_SECTIONS_ENABLED' openwrt/main.js ||
    ! grep -q 'setSubscriptionSectionsEnabled' openwrt/main.js; then
    fail 'LuCI must use one all-sections subscription apply endpoint'
fi

if sed -n '/async function handleApply()/,/^}/p' openwrt/main.js \
    | grep -q 'for (const \[sectionCode, changes\]'; then
    fail 'LuCI must not apply subscription sections one by one'
fi

if ! grep -q '^set_subscription_sections_enabled() {' openwrt/runtime-0.7.20/usr/bin/podkop; then
    fail 'runtime must provide an all-sections subscription apply endpoint'
fi

if ! grep -q 'run_with_timeout 900 env PODKOP_PATCH_VERSION=' openwrt/runtime-0.7.20/usr/bin/podkop; then
    fail 'web patch update timeout must allow the transactional installer to finish or roll back'
fi

if ! sed -n '/^has_latest_subscription_backend() {/,/^}/p' i |
        grep -q 'run_with_timeout 900 env PODKOP_PATCH_VERSION=' ||
    ! grep -q "sed -i 's/run_with_timeout 240 env PODKOP_PATCH_VERSION=/run_with_timeout 900 env PODKOP_PATCH_VERSION=/g'" i; then
    fail 'installer must upgrade and verify the safe web patch update timeout on existing routers'
fi

if ! sed -n '/^set_subscription_sections_enabled() {/,/^}/p' openwrt/runtime-0.7.20/usr/bin/podkop \
    | grep -q 'subscription_action_lock_acquire'; then
    fail 'subscription apply must coordinate with other subscription mutations'
fi

if ! grep -q 'set_subscription_sections_enabled' i ||
    ! grep -q 'subscription_apply_v2' i; then
    fail 'installer must upgrade existing patched runtimes to the new apply contract'
fi

if ! sed -n '/^has_latest_subscription_backend() {/,/^}/p' i \
        | grep -q "grep -q '\^set_subscription_sections_enabled)'" ||
    ! grep -q "! grep -q '\^set_subscription_sections_enabled)' /usr/bin/podkop" i; then
    fail 'installer capability and upgrade checks must require the apply v2 dispatcher entry'
fi

if ! grep -q 'APPLY_V2_UPGRADE_FILE="podkop-subscription-apply-v2-upgrade.sh"' i ||
    ! grep -q 'download "$RAW_BASE/$APPLY_V2_UPGRADE_FILE"' i ||
    ! grep -q 'download "$RAW_BASE/$RUNTIME_0720_PODKOP_FILE" "$tmp_dir/podkop.runtime-0.7.20"' i ||
    ! grep -q 'cp "$tmp_dir/podkop.runtime-0.7.20" "$apply_v2_source"' i ||
    ! grep -q 'PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$apply_v2_source"' i ||
    ! grep -q 'sh "$tmp_dir/$APPLY_V2_UPGRADE_FILE"' i; then
    fail 'installer must download and run the apply v2 upgrade for existing routers'
fi

if ! sed -n '/^subscription_action_lock_busy() {/,/^}/p' openwrt/runtime-0.7.20/usr/bin/podkop \
    | grep -Fq '[ -n "$pid" ] || return 0'; then
    fail 'atomic action lock must treat the owner-file creation window as busy'
fi

if ! grep -q '^subscription_action_legacy_lock_busy() {' openwrt/runtime-0.7.20/usr/bin/podkop ||
    ! sed -n '/^subscription_action_lock_acquire() {/,/^}/p' openwrt/runtime-0.7.20/usr/bin/podkop \
        | grep -Fq 'set -C'; then
    fail 'new subscription mutations must bridge the legacy lock during rolling upgrades'
fi

if grep -q 'Failed to apply changes. Podkop was not changed.' openwrt/main.js; then
    fail 'UI must not claim no changes after a post-commit failure'
fi

if ! sed -n '/async function handleApply()/,/^}/p' openwrt/main.js \
    | grep -q 'await fetchSubscriptionItems("error")'; then
    fail 'UI must resynchronize subscription state after an apply error'
fi

if ! grep -q 'subscriptionsLifecycleRegistered' openwrt/main.js; then
    fail 'subscription lifecycle listener must not be registered more than once'
fi

if ! sed -n '/async function executeShellCommand({/,/\/\/ src\/helpers\/maskIP/p' openwrt/main.js \
    | grep -q 'return await withTimeout'; then
    fail 'shell command timeouts must be caught by executeShellCommand'
fi

printf '%s\n' 'PASS: subscription apply contract is coordinated and truthful'
