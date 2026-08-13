#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if ! sed -n '/function renderButton({/,/\/\/ src\/helpers\/showToast/p' openwrt/main.js \
    | grep -q 'type: "button"'; then
    fail 'shared Podkop buttons must use type="button"'
fi

if ! sed -n '/section.canTestLatency === false/,/_[(]"Test latency"[)]/p' openwrt/main.js \
    | grep -q 'type: "button"'; then
    fail 'dashboard latency button must use type="button"'
fi

if ! sed -n '/function renderSourceGroup({/,/function renderSection({/p' openwrt/main.js \
    | grep -q 'type: "button"'; then
    fail 'subscription source toggle must use type="button"'
fi

if ! sed -n '/function renderActionButton(/,/function isUniversalProfile(/p' openwrt/settings.js \
    | grep -q 'type: "button"'; then
    fail 'DNS optimizer actions must use type="button"'
fi

if grep -q 'type: "submit"' openwrt/main.js openwrt/settings.js ||
    grep -q "type: 'submit'" openwrt/main.js openwrt/settings.js; then
    fail 'Podkop custom UI must not contain submit buttons'
fi

if ! grep -q '"data-label": _("Config")' openwrt/main.js ||
    ! grep -q '"data-label": _("Status")' openwrt/main.js; then
    fail 'subscription cells must expose mobile labels'
fi

if ! grep -q '@media (max-width: 800px)' openwrt/main.js; then
    fail 'Podkop UI must include the Proton2025 mobile breakpoint'
fi

if ! grep -q '\.pdk_subscriptions-page__table thead[[:space:]]*{' openwrt/main.js ||
    ! grep -q '\.pdk_subscriptions-page__table td::before' openwrt/main.js; then
    fail 'subscription table must switch to a labelled mobile-card layout'
fi

if ! grep -q 'max-width: calc(100vw - 24px)' openwrt/main.js; then
    fail 'toasts must fit narrow viewports'
fi

if ! sed -n '/\.pdk-partial-modal__footer {/,/^}/p' openwrt/main.js \
    | grep -q 'flex-wrap: wrap'; then
    fail 'modal actions must wrap on narrow screens'
fi

if ! grep -q '@media (max-width: 520px)' openwrt/main.js ||
    ! grep -q -- '--dashboard-grid-columns: 1' openwrt/main.js; then
    fail 'dashboard must use one column on phones'
fi

if ! grep -q '#view \.cbi-page-actions' openwrt/main.js ||
    ! grep -q '#view \.cbi-tabmenu' openwrt/main.js; then
    fail 'Podkop must contain narrow LuCI actions and tabs without page overflow'
fi

if sed -n '/#view \.cbi-page-actions \.cbi-button {/,/^    }/p' openwrt/main.js \
    | grep -Eq 'flex:[[:space:]]*1 1 [0-9]+px'; then
    fail 'LuCI action buttons must not use a pixel flex-basis that becomes height in Proton2025 column layout'
fi

if ! sed -n '/function canRefreshSubscriptions()/,/^}/p' openwrt/main.js \
    | grep -q 'widget.failed || getPendingCount2(widget.pendingChanges) === 0'; then
    fail 'subscription refresh must remain available after a cache load failure, including stale pending UI state'
fi

if ! sed -n '/async function handleRefreshSubscriptions()/,/^}/p' openwrt/main.js \
    | grep -q 'canRefreshSubscriptions()'; then
    fail 'subscription refresh handler must use the recoverable refresh guard'
fi

if ! sed -n '/async function handleApply()/,/^}/p' openwrt/main.js \
    | grep -q 'result.data?.state === "rollback_failed"' ||
    ! sed -n '/function getSubscriptionActionErrorMessage/,/^}/p' openwrt/main.js \
    | grep -q 'case "rollback_failed"'; then
    fail 'subscription apply must report an unverified rollback truthfully'
fi

printf '%s\n' 'PASS: Podkop UI regression guards are present'
