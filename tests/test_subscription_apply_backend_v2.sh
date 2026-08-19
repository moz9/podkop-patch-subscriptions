#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
runtime="$repo_root/openwrt/runtime-0.7.20/usr/bin/podkop"
upgrade="$repo_root/openwrt/podkop-subscription-apply-v2-upgrade.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

grep -Fqx '# subscription_apply_v2 begin' "$runtime" ||
    fail 'canonical runtime is missing the subscription_apply_v2 block'
grep -Fqx '# subscription_apply_v2 end' "$runtime" ||
    fail 'canonical runtime has an incomplete subscription_apply_v2 block'
grep -q '^set_subscription_sections_enabled() {' "$runtime" ||
    fail 'canonical runtime is missing the v2 endpoint'
grep -q '^set_subscription_sections_enabled)' "$runtime" ||
    fail 'canonical dispatcher does not expose the v2 endpoint'
grep -q '^subscription_action_lock_dir() {' "$runtime" ||
    fail 'subscription action lock is not atomic-directory based'

[ -f "$upgrade" ] || fail 'existing patched runtimes need a dedicated v2 upgrade script'
grep -Fq '# subscription_apply_v2 begin' "$upgrade" ||
    fail 'upgrade script does not carry the v2 capability'
grep -Fq 'set_subscription_sections_enabled)' "$upgrade" ||
    fail 'upgrade script does not install the v2 dispatcher case'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
cp "$(command -v jq)" "$tmp/jq"

sed 's/\r$//' "$runtime" |
    sed -n '/^# subscription_apply_v2 begin$/,/^# subscription_apply_v2 end$/p' > "$tmp/backend.sh"

cat > "$tmp/uci" <<'UCI_EOF'
#!/bin/sh
set -eu

quiet=0
if [ "${1:-}" = "-q" ]; then
    quiet=1
    shift
fi

command="${1:-}"
shift || true
stage="${TEST_UCI_CONFIG}.stage"

case "$command" in
delete)
    : > "$stage"
    ;;
add_list)
    value="${1#*=}"
    printf '%s\n' "$value" >> "$stage"
    ;;
commit)
    [ -f "$stage" ] || cp "$TEST_UCI_CONFIG" "$stage"
    mv "$stage" "$TEST_UCI_CONFIG"
    count=0
    [ ! -f "$TEST_STATE_DIR/commit-count" ] || count="$(cat "$TEST_STATE_DIR/commit-count")"
    printf '%s\n' "$((count + 1))" > "$TEST_STATE_DIR/commit-count"
    ;;
revert)
    rm -f "$stage"
    ;;
*)
    [ "$quiet" -eq 1 ] || printf 'unsupported fake uci command: %s\n' "$command" >&2
    exit 1
    ;;
esac
UCI_EOF
chmod +x "$tmp/uci"

cat > "$tmp/harness.sh" <<'HARNESS_EOF'
#!/bin/sh
set -eu

tmp="$1"
PATH="$tmp:$PATH"
export PATH
PODKOP_CONFIG="$tmp/config/podkop"
SUBSCRIPTION_CACHE_DIR="$tmp/subscriptions"
TEST_UCI_CONFIG="$PODKOP_CONFIG"
TEST_STATE_DIR="$tmp"
export TEST_UCI_CONFIG TEST_STATE_DIR

mkdir -p "$tmp/config" "$SUBSCRIPTION_CACHE_DIR"
: > "$PODKOP_CONFIG"

id1=11111111111111111111111111111111
id2=22222222222222222222222222222222
printf '%s\n%s\n' link-one link-two > "$SUBSCRIPTION_CACHE_DIR/main.all.links"
printf '%s\n%s\n' link-one link-two > "$SUBSCRIPTION_CACHE_DIR/main.links"
printf '%s\n' '[
  {"id":"11111111111111111111111111111111","supported":true,"enabled":true},
  {"id":"22222222222222222222222222222222","supported":true,"enabled":true}
]' > "$SUBSCRIPTION_CACHE_DIR/main.items.json"

validate_subscription_section_name() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
}
validate_subscription_urltest_section() {
    [ "$1" = main ]
}
validate_subscription_link_id() {
    [ "${#1}" -eq 32 ] && ! printf '%s' "$1" | grep -q '[^A-Fa-f0-9]'
}
get_subscription_items_cache_path() {
    printf '%s/%s.items.json\n' "$SUBSCRIPTION_CACHE_DIR" "$1"
}
get_subscription_cache_path() {
    printf '%s/%s.links\n' "$SUBSCRIPTION_CACHE_DIR" "$1"
}
collect_subscription_excluded_ids() {
    cp "$PODKOP_CONFIG" "$2"
}
config_load() {
    :
}
apply_subscription_exclusions_to_cached_links() {
    section="$1"
    if grep -Fxq "$id1" "$PODKOP_CONFIG"; then
        printf '%s\n' link-two > "$SUBSCRIPTION_CACHE_DIR/$section.links"
    else
        printf '%s\n%s\n' link-one link-two > "$SUBSCRIPTION_CACHE_DIR/$section.links"
    fi
    SUBSCRIPTION_CACHE_CHANGED=1
}
subscription_action_lock_acquire() {
    mkdir "$tmp/action.lock" 2>/dev/null
}
subscription_action_lock_release() {
    rmdir "$tmp/action.lock" 2>/dev/null || true
}

. "$tmp/backend.sh"

subscription_apply_v2_reload() {
    count=0
    [ ! -f "$tmp/reload-count" ] || count="$(cat "$tmp/reload-count")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$tmp/reload-count"
    if [ -f "$tmp/fail-reload-once" ]; then
        rm -f "$tmp/fail-reload-once"
        return 1
    fi
    return 0
}

payload='{"sections":[{"section":"main","changes":[{"id":"11111111111111111111111111111111","enabled":false}]}]}'
result="$(set_subscription_sections_enabled "$payload")"
[ "$(printf '%s' "$result" | jq -r '.success')" = true ]
[ "$(printf '%s' "$result" | jq -r '.state')" = success ]
[ "$(printf '%s' "$result" | jq -r '.committed')" = true ]
[ "$(cat "$tmp/reload-count")" -eq 1 ]
[ "$(cat "$tmp/commit-count")" -eq 1 ]
grep -Fxq "$id1" "$PODKOP_CONFIG"
[ "$(cat "$SUBSCRIPTION_CACHE_DIR/main.links")" = link-two ]

cp "$PODKOP_CONFIG" "$tmp/config-before-rollback"
cp "$SUBSCRIPTION_CACHE_DIR/main.links" "$tmp/cache-before-rollback"
: > "$tmp/fail-reload-once"
payload='{"sections":[{"section":"main","changes":[{"id":"11111111111111111111111111111111","enabled":true}]}]}'
if result="$(set_subscription_sections_enabled "$payload")"; then
    printf '%s\n' 'reload failure unexpectedly succeeded' >&2
    exit 1
fi
[ "$(printf '%s' "$result" | jq -r '.success')" = false ]
[ "$(printf '%s' "$result" | jq -r '.state')" = rolled_back ]
[ "$(printf '%s' "$result" | jq -r '.phase')" = reload ]
[ "$(printf '%s' "$result" | jq -r '.rolledBack')" = true ]
cmp -s "$tmp/config-before-rollback" "$PODKOP_CONFIG"
cmp -s "$tmp/cache-before-rollback" "$SUBSCRIPTION_CACHE_DIR/main.links"
[ "$(cat "$tmp/reload-count")" -eq 3 ]
[ "$(cat "$tmp/commit-count")" -eq 2 ]

signal_result="$tmp/signal-rollback-success.json"
if (
    SUBSCRIPTION_APPLY_V2_COMMITTED=1
    SUBSCRIPTION_APPLY_V2_STAGED=1
    SUBSCRIPTION_APPLY_V2_CHANGED=1
    subscription_apply_v2_restore() { return 0; }
    subscription_apply_v2_cleanup() { :; }
    subscription_apply_v2_interrupted
) > "$signal_result"; then
    printf '%s\n' 'interrupted committed apply unexpectedly returned success' >&2
    exit 1
else
    [ "$?" -eq 130 ]
fi
[ "$(jq -r '.state' "$signal_result")" = rolled_back ]
[ "$(jq -r '.committed' "$signal_result")" = true ]
[ "$(jq -r '.rolledBack' "$signal_result")" = true ]

signal_result="$tmp/signal-rollback-failed.json"
if (
    SUBSCRIPTION_APPLY_V2_COMMITTED=1
    SUBSCRIPTION_APPLY_V2_STAGED=1
    SUBSCRIPTION_APPLY_V2_CHANGED=1
    subscription_apply_v2_restore() { return 1; }
    subscription_apply_v2_cleanup() { :; }
    subscription_apply_v2_interrupted
) > "$signal_result"; then
    printf '%s\n' 'interrupted apply with failed rollback unexpectedly returned success' >&2
    exit 1
else
    [ "$?" -eq 130 ]
fi
[ "$(jq -r '.state' "$signal_result")" = rollback_failed ]
[ "$(jq -r '.committed' "$signal_result")" = true ]
[ "$(jq -r '.rolledBack' "$signal_result")" = false ]

signal_result="$tmp/signal-staged-revert-success.json"
if (
    SUBSCRIPTION_APPLY_V2_COMMITTED=0
    SUBSCRIPTION_APPLY_V2_STAGED=1
    SUBSCRIPTION_APPLY_V2_CHANGED=1
    uci() { return 0; }
    subscription_apply_v2_cleanup() { :; }
    subscription_apply_v2_interrupted
) > "$signal_result"; then
    printf '%s\n' 'interrupted staged apply unexpectedly returned success' >&2
    exit 1
else
    [ "$?" -eq 130 ]
fi
[ "$(jq -r '.state' "$signal_result")" = rolled_back ]
[ "$(jq -r '.committed' "$signal_result")" = false ]
[ "$(jq -r '.rolledBack' "$signal_result")" = true ]

signal_result="$tmp/signal-staged-revert-failed.json"
if (
    SUBSCRIPTION_APPLY_V2_COMMITTED=0
    SUBSCRIPTION_APPLY_V2_STAGED=1
    SUBSCRIPTION_APPLY_V2_CHANGED=1
    uci() { return 1; }
    subscription_apply_v2_cleanup() { :; }
    subscription_apply_v2_interrupted
) > "$signal_result"; then
    printf '%s\n' 'interrupted staged apply with failed revert unexpectedly returned success' >&2
    exit 1
else
    [ "$?" -eq 130 ]
fi
[ "$(jq -r '.state' "$signal_result")" = rollback_failed ]
[ "$(jq -r '.committed' "$signal_result")" = false ]
[ "$(jq -r '.rolledBack' "$signal_result")" = false ]

invalid_batch='{"sections":[{"section":"main","changes":[{"id":"11111111111111111111111111111111","enabled":true}]},{"section":"not_subscription","changes":[{"id":"22222222222222222222222222222222","enabled":false}]}]}'
config_hash="$(sha256sum "$PODKOP_CONFIG" | awk '{print $1}')"
if result="$(set_subscription_sections_enabled "$invalid_batch")"; then
    printf '%s\n' 'partially invalid batch unexpectedly succeeded' >&2
    exit 1
fi
[ "$(printf '%s' "$result" | jq -r '.phase')" = validation ]
[ "$(sha256sum "$PODKOP_CONFIG" | awk '{print $1}')" = "$config_hash" ]
[ "$(cat "$tmp/commit-count")" -eq 2 ]
[ "$(cat "$tmp/reload-count")" -eq 3 ]

invalid='{"sections":[{"section":"main","changes":[{"id":"not-an-id","enabled":false}]}]}'
config_hash="$(sha256sum "$PODKOP_CONFIG" | awk '{print $1}')"
if result="$(set_subscription_sections_enabled "$invalid")"; then
    printf '%s\n' 'invalid payload unexpectedly succeeded' >&2
    exit 1
fi
[ "$(printf '%s' "$result" | jq -r '.success')" = false ]
[ "$(printf '%s' "$result" | jq -r '.phase')" = validation ]
[ "$(sha256sum "$PODKOP_CONFIG" | awk '{print $1}')" = "$config_hash" ]
[ "$(cat "$tmp/reload-count")" -eq 3 ]
[ "$(cat "$tmp/commit-count")" -eq 2 ]
HARNESS_EOF
chmod +x "$tmp/harness.sh"

if ! sh -x "$tmp/harness.sh" "$tmp" > "$tmp/harness.log" 2>&1; then
    sed -n '1,260p' "$tmp/harness.log" >&2
    fail 'v2 transaction/rollback harness failed'
fi

for version in 0.7.19 0.7.20 0.7.21 0.7.22; do
    fixture="$tmp/podkop-$version"
    backup="$tmp/podkop-$version.backup"
    cat > "$tmp/runtime.fixture" <<'FIXTURE_EOF'
#!/bin/sh

set_subscription_links_enabled() {
    :
}

subscription_update_section_handler() {
    :
}

subscription_action_lock_file() {
    echo "/tmp/podkop-subscription-action.lock"
}

subscription_action_lock_pid_alive() {
    [ -d "/proc/$1" ]
}

subscription_action_lock_busy() {
    [ -s "$(subscription_action_lock_file)" ]
}

subscription_action_lock_acquire() {
    printf '%s %s\n' "$$" "$1" > "$(subscription_action_lock_file)"
}

subscription_action_lock_release() {
    rm -f "$(subscription_action_lock_file)"
}

# sing-box funcs
show_help() {
    cat <<'HELP_EOF'
Available commands:
    set_subscription_links_enabled
                            Enable or disable multiple subscription proxy items by id
HELP_EOF
}

case "${1:-}" in
set_subscription_links_enabled)
    shift
    set_subscription_links_enabled "$@"
    ;;
show_version)
    echo "@VERSION@"
    ;;
esac
FIXTURE_EOF
    sed "s/@VERSION@/$version/" "$tmp/runtime.fixture" > "$fixture"
    chmod +x "$fixture"

    PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$fixture" \
        PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$runtime" \
        PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$backup" \
        sh "$upgrade" > "$tmp/upgrade-$version.log" ||
        fail "v2 upgrade failed for Podkop $version fixture"

    [ -f "$backup" ] || fail "v2 upgrade did not back up Podkop $version fixture"
    [ "$(grep -Fxc '# subscription_apply_v2 begin' "$fixture")" -eq 1 ] ||
        fail "v2 upgrade did not install exactly one backend block for Podkop $version"
    [ "$(grep -c '^set_subscription_sections_enabled)' "$fixture")" -eq 1 ] ||
        fail "v2 upgrade did not install exactly one dispatcher for Podkop $version"
    [ "$(grep -c '^subscription_action_lock_dir() {' "$fixture")" -eq 1 ] ||
        fail "v2 upgrade did not install exactly one atomic lock for Podkop $version"
    sh -n "$fixture" || fail "v2-upgraded Podkop $version fixture has invalid shell syntax"

    if invalid_result="$("$fixture" set_subscription_sections_enabled '{}')"; then
        fail "v2-upgraded Podkop $version fixture accepted an invalid payload"
    fi
    [ "$(printf '%s' "$invalid_result" | jq -r '.phase')" = validation ] ||
        fail "v2-upgraded Podkop $version fixture did not return structured validation JSON"

    PODKOP_SUBSCRIPTION_APPLY_V2_TARGET="$fixture" \
        PODKOP_SUBSCRIPTION_APPLY_V2_SOURCE="$runtime" \
        PODKOP_SUBSCRIPTION_APPLY_V2_BACKUP="$tmp/unexpected-second-backup-$version" \
        sh "$upgrade" > "$tmp/upgrade-$version-noop.log" ||
        fail "v2 upgrade is not idempotent for Podkop $version"
    grep -Fq 'already installed' "$tmp/upgrade-$version-noop.log" ||
        fail "v2 upgrade did not report no-op for Podkop $version"
done

printf '%s\n' 'PASS: subscription apply backend v2 validates, commits once, rolls back, and upgrades 0.7.19-0.7.22'
