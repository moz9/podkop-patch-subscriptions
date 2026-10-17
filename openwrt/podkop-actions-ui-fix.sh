#!/bin/sh
set -eu

target="/usr/bin/podkop"
tmp="${target}.tmp.$$"

if grep -q "get_subscription_items_cached" "$target" 2>/dev/null; then
	exit 0
fi

awk '
BEGIN {
	inserted_func = 0
	inserted_help = 0
	inserted_case = 0
}

!inserted_func && $0 == "validate_subscription_link_id() {" {
	print "get_subscription_items_cached() {"
	print "    local section=\"$1\""
	print "    local cache_path"
	print ""
	print "    if [ -z \"$section\" ]; then"
	print "        echo \"[]\""
	print "        return 1"
	print "    fi"
	print ""
	print "    cache_path=\"$(get_subscription_items_cache_path \"$section\")\""
	print "    if [ ! -s \"$cache_path\" ]; then"
	print "        echo \"[]\""
	print "        return 0"
	print "    fi"
	print ""
	print "    cat \"$cache_path\""
	print "}"
	print ""
	inserted_func = 1
}

!inserted_help && $0 == "    set_subscription_link_enabled" {
	print "    get_subscription_items_cached"
	print "                            Show cached subscription proxy items without refresh"
	inserted_help = 1
}

!inserted_case && $0 == "set_subscription_link_enabled)" {
	print "get_subscription_items_cached)"
	print "    get_subscription_items_cached \"$2\""
	print "    ;;"
	inserted_case = 1
}

{ print }

END {
	if (!inserted_func || !inserted_case) {
		exit 1
	}
}
' "$target" > "$tmp" || {
	rm -f "$tmp"
	exit 1
}

cat "$tmp" > "$target"
rm -f "$tmp"
chmod 755 "$target"
