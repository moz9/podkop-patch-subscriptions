#!/bin/sh
set -eu

target="${PODKOP_DNS_FAILOVER_TARGET:-/usr/bin/podkop}"
syntax_shell="${PODKOP_DNS_FAILOVER_SHELL:-ash}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

[ -f "$target" ] || {
    echo "ERROR: podkop runtime is missing: $target" >&2
    exit 1
}

if grep -q '^load_active_dns_settings() {' "$target" 2> /dev/null &&
    grep -q 'dns_failover_active_slot' "$target" 2> /dev/null; then
    exit 0
fi

awk '
BEGIN {
    inserted = 0
    in_dns = 0
    in_check = 0
    dns_values = 0
    check_values = 0
}

$0 == "sing_box_configure_dns() {" && !inserted {
    print "load_active_dns_settings() {"
    print "    local failover_enabled active_slot secondary_dns_type secondary_dns_server secondary_bootstrap_dns_server"
    print ""
    print "    config_get ACTIVE_DNS_TYPE \"settings\" \"dns_type\" \"doh\""
    print "    config_get ACTIVE_DNS_SERVER \"settings\" \"dns_server\" \"1.1.1.1\""
    print "    config_get ACTIVE_BOOTSTRAP_DNS_SERVER \"settings\" \"bootstrap_dns_server\" \"77.88.8.8\""
    print "    config_get_bool failover_enabled \"settings\" \"dns_failover_enabled\" \"0\""
    print "    config_get active_slot \"settings\" \"dns_failover_active_slot\" \"primary\""
    print ""
    print "    ACTIVE_DNS_SLOT=\"primary\""
    print "    if [ \"$failover_enabled\" -eq 1 ] && [ \"$active_slot\" = \"secondary\" ]; then"
    print "        config_get secondary_dns_type \"settings\" \"secondary_dns_type\""
    print "        config_get secondary_dns_server \"settings\" \"secondary_dns_server\""
    print "        config_get secondary_bootstrap_dns_server \"settings\" \"secondary_bootstrap_dns_server\""
    print "        if [ -n \"$secondary_dns_type\" ] && [ -n \"$secondary_dns_server\" ] && [ -n \"$secondary_bootstrap_dns_server\" ]; then"
    print "            ACTIVE_DNS_TYPE=\"$secondary_dns_type\""
    print "            ACTIVE_DNS_SERVER=\"$secondary_dns_server\""
    print "            ACTIVE_BOOTSTRAP_DNS_SERVER=\"$secondary_bootstrap_dns_server\""
    print "            ACTIVE_DNS_SLOT=\"secondary\""
    print "        else"
    print "            log \"Secondary DNS pair is incomplete, using the primary pair\" \"warn\""
    print "        fi"
    print "    fi"
    print "}"
    print ""
    print
    inserted = 1
    in_dns = 1
    next
}

in_dns && $0 ~ /^[[:space:]]+local dns_type dns_server bootstrap_dns_server dns_domain_resolver dns_server_address$/ {
    print
    print "    load_active_dns_settings"
    print "    dns_type=\"$ACTIVE_DNS_TYPE\""
    print "    dns_server=\"$ACTIVE_DNS_SERVER\""
    print "    bootstrap_dns_server=\"$ACTIVE_BOOTSTRAP_DNS_SERVER\""
    dns_values = 1
    next
}

in_dns && dns_values && $0 ~ /^[[:space:]]+config_get (dns_type|dns_server|bootstrap_dns_server) / {
    next
}

$0 == "check_dns_available() {" {
    in_check = 1
    print
    next
}

in_check && $0 ~ /^[[:space:]]+local dns_type dns_server bootstrap_dns_server$/ {
    print "    local dns_type dns_server bootstrap_dns_server"
    print "    load_active_dns_settings"
    print "    dns_type=\"$ACTIVE_DNS_TYPE\""
    print "    dns_server=\"$ACTIVE_DNS_SERVER\""
    print "    bootstrap_dns_server=\"$ACTIVE_BOOTSTRAP_DNS_SERVER\""
    check_values = 1
    next
}

in_check && check_values && $0 ~ /^[[:space:]]+config_get (dns_type|dns_server|bootstrap_dns_server) / {
    next
}

in_dns && $0 == "}" {
    in_dns = 0
}

in_check && $0 == "}" {
    in_check = 0
}

{ print }

END {
    if (!inserted || !dns_values || !check_values) {
        exit 42
    }
}
' "$target" > "$tmp" || {
    echo "ERROR: failed to add DNS failover runtime support" >&2
    exit 1
}

grep -q '^load_active_dns_settings() {' "$tmp" || exit 1
grep -q 'ACTIVE_DNS_SLOT="secondary"' "$tmp" || exit 1
"$syntax_shell" -n "$tmp"
cat "$tmp" > "$target"
chmod 755 "$target"
