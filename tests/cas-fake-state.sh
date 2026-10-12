# Explicit adapter for the JSON (or exclusion-line) UCI models in shell tests.
# Production begin/revision/publish and the setter's revision checks remain real.
# Only UCI serialization and private mutation are substituted.
eval "$(sed -n '/^# subscription_cas_v1 begin$/,/^# subscription_cas_v1 end$/p' "$CAS_TEST_RUNTIME")"
for cas_helper in subscription_resource_limits subscription_resource_bytes subscription_resource_memory; do
    eval "$(sed -n "/^$cas_helper() {$/,/^}$/p" "$CAS_TEST_RUNTIME")"
done
subscription_cas_config_load() { :; } # Fake config_get reads the file directly.
subscription_cas_config_json() {
    if [ "${CAS_TEST_CONFIG_FORMAT:-json}" = exclusions ]; then
        jq -Rn '{main:{connection_type:"proxy",proxy_config_type:"subscription_urltest",subscription_excluded_link_ids:[inputs]},settings:{}}' < "$SUBSCRIPTION_CAS_DIR/config/podkop"
    else
        # These models contain subscription sections plus settings. Supply their
        # invariant UCI types; explicit fields override defaults and still reject
        # through the production revision's independent section-type check.
        jq -ceS 'select(type=="object") | .settings=(.settings//{})
          | with_entries(if .key=="settings" then . else
              .value=({connection_type:"proxy",proxy_config_type:"subscription_urltest"}+.value)
            end)' "$SUBSCRIPTION_CAS_DIR/config/podkop"
    fi
}
subscription_cas_uci() (
    if [ "${SUBSCRIPTION_CAS_ACTIVE:-0}" = 1 ]; then
        PODKOP_CONFIG="$SUBSCRIPTION_CAS_DIR/config/podkop"
        TEST_UCI_CONFIG="$PODKOP_CONFIG"; export TEST_UCI_CONFIG
    fi
    uci "$@"
)
# Fixtures without service diagnostics still have a private, absent evidence path.
if ! command -v subscription_services_cache_path >/dev/null; then
    subscription_services_cache_path() { printf '%s/service-checks/%s.json\n' "$SUBSCRIPTION_CACHE_DIR" "$1"; }
fi
if ! command -v get_subscription_all_cache_path >/dev/null; then
    get_subscription_all_cache_path() { printf '%s/%s.all.links\n' "$SUBSCRIPTION_CACHE_DIR" "$1"; }
fi
cas_test_fresh_payload() (
    # Explicit fresh-client snapshot; callers testing stale/malformed/missing
    # revisions must call the setter directly instead of using this helper.
    cas_payload="$1"
    cas_dir="$(mktemp -d /tmp/podkop-fixture-cas-XXXXXX)" || exit 1
    trap 'rm -rf "$cas_dir"' EXIT
    subscription_cas_begin "$cas_dir" || exit 1
    printf '%s' "$cas_payload" | jq -r '.sections[].section' > "$cas_dir/sections" || exit 1
    while IFS= read -r cas_section; do
        cas_revision="$(subscription_section_revision "$cas_section")" || exit 1
        cas_payload="$(printf '%s' "$cas_payload" | jq --arg section "$cas_section" --arg revision "$cas_revision" '.sections |= map(if .section==$section then .expectedRevision=$revision else . end)')" || exit 1
    done < "$cas_dir/sections"
    printf '%s\n' "$cas_payload"
)
cas_test_apply_fresh() {
    local cas_payload
    cas_payload="$(cas_test_fresh_payload "$1")" || return 1
    set_subscription_sections_enabled "$cas_payload"
}
