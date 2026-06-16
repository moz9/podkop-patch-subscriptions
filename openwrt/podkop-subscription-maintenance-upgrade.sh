#!/bin/sh
set -eu

target="${PODKOP_MAINTENANCE_TARGET:-/usr/bin/podkop}"
tmp="${target}.tmp.$$"

if ! grep -q "get_subscription_items_cached" "$target" 2>/dev/null; then
	exit 0
fi

if ! grep -q "PODKOP_SKIP_LIST_UPDATE" "$target" 2>/dev/null; then
	awk '
	$0 == "    list_update &" {
		print "    if [ \"$PODKOP_SKIP_LIST_UPDATE\" = \"1\" ]; then"
		print "        log \"Skipping lists update for this reload\" \"debug\""
		print "    else"
		print "        list_update &"
		print "        echo $! > /var/run/podkop_list_update.pid"
		print "    fi"
		getline
		next
	}
	{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp"
fi

if ! grep -q "PODKOP_SUBSCRIPTION_CACHE_ONLY" "$target" 2>/dev/null; then
	awk '
	BEGIN {
		state = 0
	}

	state == 0 && $0 == "    if ! refresh_subscription_cache \"$section\"; then" {
		state = 1
		next
	}

	state == 1 && index($0, "log \"Using cached subscription for section") > 0 {
		state = 2
		next
	}

	state == 2 && $0 == "    fi" {
		state = 3
		next
	}

	state == 3 && $0 == "" {
		state = 4
		next
	}

	state == 4 && $0 == "    cache_path=\"$(get_subscription_cache_path \"$section\")\"" {
		print "    cache_path=\"$(get_subscription_cache_path \"$section\")\""
		print "    if [ \"$PODKOP_SUBSCRIPTION_CACHE_ONLY\" = \"1\" ] && [ -s \"$cache_path\" ]; then"
		print "        log \"Using cached subscription for section '\''$section'\''\" \"debug\""
		print "    elif ! refresh_subscription_cache \"$section\"; then"
		print "        log \"Using cached subscription for section '\''$section'\''\" \"warn\""
		print "    fi"
		state = 0
		next
	}

	state != 0 {
		print "    if ! refresh_subscription_cache \"$section\"; then"
		print "        log \"Using cached subscription for section '\''$section'\''\" \"warn\""
		print "    fi"
		if (state >= 3) {
			print ""
		}
		state = 0
	}

	{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp"
fi

awk '
$0 == "        if ! /etc/init.d/podkop reload > /dev/null 2>&1; then" {
	print "        if ! PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /etc/init.d/podkop reload > /dev/null 2>&1; then"
	next
}

$0 == "    /etc/init.d/podkop reload > /dev/null 2>&1" {
	print "    PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /etc/init.d/podkop reload > /dev/null 2>&1"
	next
}

{ print }
' "$target" > "$tmp" || {
	rm -f "$tmp"
	exit 1
}
cat "$tmp" > "$target"
rm -f "$tmp"

chmod 755 "$target"
