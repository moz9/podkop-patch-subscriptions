#!/bin/sh
set -eu

target="${PODKOP_MAINTENANCE_TARGET:-/usr/bin/podkop}"
tmp="${target}.tmp.$$"
helper_target="${PODKOP_MAINTENANCE_HELPERS_TARGET:-/usr/lib/podkop/helpers.sh}"
helper_tmp="${helper_target}.tmp.$$"

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

needs_stop_tree=0
if ! grep -q "stop_stale_list_update_downloads" "$target" 2>/dev/null; then
	needs_stop_tree=1
	awk '
	$0 == "stop_main() {" {
		print "kill_process_tree() {"
		print "    local pid=\"$1\""
		print "    local child"
		print ""
		print "    [ -n \"$pid\" ] || return 0"
		print "    [ -d \"/proc/$pid\" ] || return 0"
		print ""
		print "    if [ -r \"/proc/$pid/task/$pid/children\" ]; then"
		print "        for child in $(cat \"/proc/$pid/task/$pid/children\" 2> /dev/null); do"
		print "            kill_process_tree \"$child\""
		print "        done"
		print "    fi"
		print ""
		print "    kill \"$pid\" 2> /dev/null || true"
		print "}"
		print ""
		print "stop_stale_list_update_downloads() {"
		print "    ps w 2> /dev/null | awk '\''"
		print "        /wget .*raw\\.githubusercontent\\.com\\/itdoginfo\\/allow-domains/ { print $1 }"
		print "        /curl .*raw\\.githubusercontent\\.com\\/itdoginfo\\/allow-domains/ { print $1 }"
		print "    '\'' | while read -r pid; do"
		print "        [ -n \"$pid\" ] && kill \"$pid\" 2> /dev/null || true"
		print "    done"
		print "}"
		print ""
		print
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

if [ "$needs_stop_tree" -eq 1 ]; then
	awk '
$0 == "            kill \"$pid\" 2> /dev/null" {
	print "            kill_process_tree \"$pid\""
	next
}

$0 == "        rm -f /var/run/podkop_list_update.pid" {
	print
	print "    fi"
	print "    stop_stale_list_update_downloads"
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

if ! grep -q "clash_api_wait_proxy_now" "$target" 2>/dev/null; then
	awk '
	$0 == "clash_api_set_group_proxy_raw() {" {
		print "clash_api_wait_proxy_now() {"
		print "    local clash_url=\"$1\""
		print "    local auth_header=\"$2\""
		print "    local proxy_tag=\"$3\""
		print "    local attempts=\"${4:-15}\""
		print "    local proxy_now attempt"
		print ""
		print "    for attempt in $(seq 1 \"$attempts\"); do"
		print "        proxy_now=\"$(clash_api_get_proxy_now \"$clash_url\" \"$auth_header\" \"$proxy_tag\")\""
		print "        if [ -n \"$proxy_now\" ]; then"
		print "            echo \"$proxy_now\""
		print "            return 0"
		print "        fi"
		print "        sleep 1"
		print "    done"
		print ""
		print "    return 1"
		print "}"
		print ""
		print
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

if ! grep -q "subscription_runtime_busy" "$target" 2>/dev/null; then
	awk '
	$0 == "subscription_speedtest_restore_mixed_proxy() {" {
		print "subscription_runtime_busy() {"
		print "    local status_file state"
		print ""
		print "    status_file=\"$(subscription_patch_update_status_file)\""
		print "    if [ -s \"$status_file\" ]; then"
		print "        state=\"$(jq -r '\''.state // \"\"'\'' \"$status_file\" 2> /dev/null)\""
		print "        [ \"$state\" = \"running\" ] && return 0"
		print "    fi"
		print ""
		print "    ps w 2> /dev/null | grep -E \"podkop-subscriptions-patch-update-runner|/usr/bin/podkop reload|/etc/init.d/podkop reload\" | grep -v grep > /dev/null"
		print "}"
		print ""
		print
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

if ! grep -q 'benchmark_bytes="8388608"' "$target" 2>/dev/null ||
	! grep -q "clash_ready" "$target" 2>/dev/null ||
	! grep -q "service_busy" "$target" 2>/dev/null ||
	! grep -q "clash_api_wait_proxy_now" "$target" 2>/dev/null ||
	! grep -q "restore_proxy" "$target" 2>/dev/null; then
	speedtest_function="$(mktemp)"
	cat > "$speedtest_function" <<'SPEEDTEST_EOF'
subscription_speedtest() {
    local section="$1"
    local items_cache_path active_items_file results_file clash_url auth_header selector_tag urltest_tag original_proxy restore_proxy \
        original_mixed_enabled original_mixed_port mixed_port mixed_changed mixed_address benchmark_url \
        warmup_url benchmark_bytes warmup_bytes benchmark_attempts min_size_download item_json id name tag index \
        output bytes_per_second time_total size_download http_code results_json attempt best_bytes_per_second \
        best_time_total best_size_download best_http_code clash_ready

    if [ -z "$section" ]; then
        echo '{"success":false,"error":"section_required"}'
        return 1
    fi

    if ! validate_subscription_urltest_section "$section"; then
        echo '{"success":false,"error":"section_is_not_subscription_urltest"}'
        return 1
    fi

    if subscription_runtime_busy; then
        echo '{"success":false,"error":"service_busy"}'
        return 1
    fi

    items_cache_path="$(get_subscription_items_cache_path "$section")"
    if [ ! -s "$items_cache_path" ]; then
        refresh_subscription_cache "$section" > /dev/null 2>&1 || true
    fi

    if [ ! -s "$items_cache_path" ]; then
        echo '{"success":false,"error":"subscription_cache_missing"}'
        return 1
    fi

    active_items_file="$(mktemp)"
    results_file="$(mktemp)"
    jq -c '.[] | select(.supported == true and .enabled == true)' "$items_cache_path" > "$active_items_file"

    if [ ! -s "$active_items_file" ]; then
        rm -f "$active_items_file" "$results_file"
        echo '{"success":false,"error":"no_enabled_links"}'
        return 1
    fi

    clash_url="$(get_clash_api_base_url)"
    auth_header="$(get_clash_api_auth_header)"
    selector_tag="$(get_outbound_tag_by_section "$section")"
    urltest_tag="$(get_outbound_tag_by_section "$section-urltest")"
    restore_proxy="$urltest_tag"
    original_proxy="$(clash_api_wait_proxy_now "$clash_url" "$auth_header" "$selector_tag" 15)"

    if [ -z "$original_proxy" ]; then
        rm -f "$active_items_file" "$results_file"
        echo '{"success":false,"error":"selector_not_available"}'
        return 1
    fi

    config_get original_mixed_enabled "$section" "mixed_proxy_enabled"
    config_get original_mixed_port "$section" "mixed_proxy_port"
    mixed_port="$original_mixed_port"
    [ -n "$mixed_port" ] || mixed_port="$(get_subscription_benchmark_port "$section")"
    mixed_changed=0

    if [ "$original_mixed_enabled" != "1" ] || [ -z "$original_mixed_port" ]; then
        uci -q set "podkop.$section.mixed_proxy_enabled=1"
        uci -q set "podkop.$section.mixed_proxy_port=$mixed_port"
        if ! uci commit podkop > /dev/null 2>&1; then
            rm -f "$active_items_file" "$results_file"
            echo '{"success":false,"error":"uci_commit_failed"}'
            return 1
        fi
        config_load "$PODKOP_CONFIG"
        mixed_changed=1

        if ! PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /etc/init.d/podkop reload > /dev/null 2>&1; then
            subscription_speedtest_restore_mixed_proxy "$section" "$original_mixed_enabled" "$original_mixed_port" "$mixed_changed" > /dev/null 2>&1
            rm -f "$active_items_file" "$results_file"
            echo '{"success":false,"error":"reload_failed"}'
            return 1
        fi
    fi

    mixed_address="$(get_service_listen_address)"
    if [ -z "$mixed_address" ]; then
        clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$restore_proxy" > /dev/null 2>&1 ||
            clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$original_proxy" > /dev/null 2>&1 || true
        subscription_speedtest_restore_mixed_proxy "$section" "$original_mixed_enabled" "$original_mixed_port" "$mixed_changed" > /dev/null 2>&1
        rm -f "$active_items_file" "$results_file"
        echo '{"success":false,"error":"mixed_proxy_address_missing"}'
        return 1
    fi

    clash_ready=0
    for attempt in $(seq 1 10); do
        if [ -n "$(clash_api_wait_proxy_now "$clash_url" "$auth_header" "$selector_tag" 1)" ]; then
            clash_ready=1
            break
        fi
        sleep 1
    done

    if [ "$clash_ready" -ne 1 ]; then
        clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$restore_proxy" > /dev/null 2>&1 ||
            clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$original_proxy" > /dev/null 2>&1 || true
        subscription_speedtest_restore_mixed_proxy "$section" "$original_mixed_enabled" "$original_mixed_port" "$mixed_changed" > /dev/null 2>&1
        rm -f "$active_items_file" "$results_file"
        echo '{"success":false,"error":"selector_not_available"}'
        return 1
    fi

    benchmark_bytes="8388608"
    warmup_bytes="262144"
    benchmark_attempts="2"
    min_size_download=$((benchmark_bytes * 9 / 10))
    benchmark_url="https://speed.cloudflare.com/__down?bytes=$benchmark_bytes"
    warmup_url="https://speed.cloudflare.com/__down?bytes=$warmup_bytes"
    index=1
    while IFS= read -r item_json || [ -n "$item_json" ]; do
        [ -n "$item_json" ] || continue

        id="$(echo "$item_json" | jq -r '.id')"
        name="$(echo "$item_json" | jq -r '.name // ""')"
        tag="$(get_outbound_tag_by_section "$section-$index")"

        if ! clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$tag"; then
            subscription_speedtest_result_error "$id" "$tag" "$name" "select_failed" >> "$results_file"
            index=$((index + 1))
            continue
        fi

        sleep 1
        curl -L -s -o /dev/null \
            -x "http://$mixed_address:$mixed_port" \
            --connect-timeout 6 \
            -m 10 \
            "$warmup_url" > /dev/null 2>&1 || true

        best_bytes_per_second=0
        best_time_total=0
        best_size_download=0
        best_http_code=0
        for attempt in $(seq 1 "$benchmark_attempts"); do
            output="$(
                curl -L -s -o /dev/null \
                    -x "http://$mixed_address:$mixed_port" \
                    --connect-timeout 8 \
                    -m 35 \
                    -w '%{speed_download} %{time_total} %{size_download} %{http_code}' \
                    "$benchmark_url" 2> /dev/null
            )"

            bytes_per_second="$(echo "$output" | awk '{printf "%d", $1}')"
            time_total="$(echo "$output" | awk '{print ($2 == "" ? 0 : $2)}')"
            size_download="$(echo "$output" | awk '{printf "%d", $3}')"
            http_code="$(echo "$output" | awk '{printf "%d", $4}')"

            if [ "${bytes_per_second:-0}" -gt "$best_bytes_per_second" ] &&
                [ "${size_download:-0}" -ge "$min_size_download" ] &&
                [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 400 ]; then
                best_bytes_per_second="${bytes_per_second:-0}"
                best_time_total="${time_total:-0}"
                best_size_download="${size_download:-0}"
                best_http_code="${http_code:-0}"
            fi
        done

        if [ "$best_bytes_per_second" -gt 0 ]; then
            subscription_speedtest_result_success "$id" "$tag" "$name" \
                "$best_bytes_per_second" "$best_time_total" "$best_size_download" "$best_http_code" >> "$results_file"
        else
            subscription_speedtest_result_error "$id" "$tag" "$name" "download_failed" >> "$results_file"
        fi

        index=$((index + 1))
    done < "$active_items_file"

    clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$restore_proxy" > /dev/null 2>&1 ||
        clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$original_proxy" > /dev/null 2>&1 || true
    subscription_speedtest_restore_mixed_proxy "$section" "$original_mixed_enabled" "$original_mixed_port" "$mixed_changed" > /dev/null 2>&1

    results_json="$(jq -s '.' "$results_file")"
    rm -f "$active_items_file" "$results_file"
    jq -cn --arg section "$section" --argjson results "$results_json" \
        '{success:true, section:$section, results:$results}'
}
SPEEDTEST_EOF

	awk -v replacement_file="$speedtest_function" '
	BEGIN {
		while ((getline line < replacement_file) > 0) {
			replacement[++replacement_count] = line
		}
		close(replacement_file)
		in_speedtest = 0
	}

	$0 == "subscription_speedtest() {" {
		for (i = 1; i <= replacement_count; i++) {
			print replacement[i]
		}
		in_speedtest = 1
		next
	}

	in_speedtest && $0 == "subscription_patch_update_status_file() {" {
		in_speedtest = 0
		print
		next
	}

	in_speedtest {
		next
	}

	{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp" "$speedtest_function"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp" "$speedtest_function"
fi

if ! grep -Fq 'install.sh?t=$cache_buster' "$target" 2>/dev/null; then
	patch_update_function="$(mktemp)"
	cat > "$patch_update_function" <<'PATCH_UPDATE_EOF'
subscription_patch_update() {
    local status_file runner

    status_file="$(subscription_patch_update_status_file)"
    runner="/tmp/podkop-subscriptions-patch-update-runner.sh"

    cat > "$runner" << 'EOF'
#!/bin/ash
status_file="/tmp/podkop-subscriptions-patch-update.json"
log_file="/tmp/podkop-subscriptions-patch-update.log"

write_status() {
    local state="$1"
    local message="$2"
    local log_tail="$3"
    jq -cn --arg state "$state" --arg message "$message" \
        --arg updatedAt "$(date -Iseconds 2> /dev/null || date)" \
        --arg logTail "$log_tail" \
        '{state:$state, message:$message, updatedAt:$updatedAt, logTail:$logTail}' > "$status_file"
}

write_status "running" "patch_update_running" ""

tmp="/tmp/podkop-subscriptions-install.sh"
cache_buster="$(date +%s 2> /dev/null || echo $$)"
install_url="https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/main/openwrt/install.sh?t=$cache_buster"
download_ok=0

if command -v curl > /dev/null 2>&1; then
    if curl -fsSL --connect-timeout 10 -m 30 -o "$tmp" "$install_url" > "$log_file" 2>&1; then
        download_ok=1
    else
        for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
            if curl -fsSL --connect-timeout 10 -m 30 \
                --resolve "raw.githubusercontent.com:443:$ip" \
                -o "$tmp" "$install_url" >> "$log_file" 2>&1; then
                download_ok=1
                break
            fi
        done
    fi
else
    if wget -T 30 -t 1 -O "$tmp" "$install_url" > "$log_file" 2>&1; then
        download_ok=1
    else
        for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
            if wget -T 30 -t 1 --no-check-certificate --header="Host: raw.githubusercontent.com" \
                -O "$tmp" "https://$ip/moz9/podkop-patch-subscriptions/main/openwrt/install.sh?t=$cache_buster" >> "$log_file" 2>&1; then
                download_ok=1
                break
            fi
        done
    fi
fi

if [ "$download_ok" -ne 1 ] || [ ! -s "$tmp" ]; then
    write_status "error" "download_failed" "$(tail -n 20 "$log_file" 2> /dev/null)"
    exit 1
fi

if PODKOP_PATCH_VERSION="${PODKOP_PATCH_VERSION:-main}" sh "$tmp" >> "$log_file" 2>&1; then
    write_status "success" "patch_update_success" "$(tail -n 20 "$log_file" 2> /dev/null)"
else
    write_status "error" "install_failed" "$(tail -n 20 "$log_file" 2> /dev/null)"
    exit 1
fi
EOF

    chmod +x "$runner"
    "$runner" > /dev/null 2>&1 &

    echo '{"success":true,"started":true}'
}
PATCH_UPDATE_EOF

	awk -v replacement_file="$patch_update_function" '
	BEGIN {
		while ((getline line < replacement_file) > 0) {
			replacement[++replacement_count] = line
		}
		close(replacement_file)
		in_patch_update = 0
	}

	$0 == "subscription_patch_update() {" {
		for (i = 1; i <= replacement_count; i++) {
			print replacement[i]
		}
		in_patch_update = 1
		next
	}

	in_patch_update && $0 == "get_subscription_patch_update_status() {" {
		in_patch_update = 0
		print
		next
	}

	in_patch_update {
		next
	}

	{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp" "$patch_update_function"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp" "$patch_update_function"
fi

if ! grep -Fq 'wget -T 30 -t 1 -O "$filepath" "$url"' "$target" 2>/dev/null; then
	subscription_download_function="$(mktemp)"
	cat > "$subscription_download_function" <<'SUBSCRIPTION_DOWNLOAD_EOF'
download_subscription_to_file() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"
    local attempt

    for attempt in $(seq 1 "$retries"); do
        rm -f "$filepath"
        if command -v curl > /dev/null 2>&1; then
            if [ -n "$http_proxy_address" ]; then
                curl -fsSL -x "http://$http_proxy_address" --connect-timeout 10 -m 30 -o "$filepath" "$url" &&
                    [ -s "$filepath" ] && return 0
            else
                curl -fsSL --connect-timeout 10 -m 30 -o "$filepath" "$url" && [ -s "$filepath" ] && return 0
            fi
        else
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    wget -T 30 -t 1 -O "$filepath" "$url" && [ -s "$filepath" ] && return 0
            else
                wget -T 30 -t 1 -O "$filepath" "$url" && [ -s "$filepath" ] && return 0
            fi
        fi

        log "Attempt $attempt/$retries to download subscription failed" "warn"
        sleep "$wait"
    done

    return 1
}
SUBSCRIPTION_DOWNLOAD_EOF

	awk -v replacement_file="$subscription_download_function" '
	BEGIN {
		while ((getline line < replacement_file) > 0) {
			replacement[++replacement_count] = line
		}
		close(replacement_file)
		in_download = 0
	}

	$0 == "download_subscription_to_file() {" {
		for (i = 1; i <= replacement_count; i++) {
			print replacement[i]
		}
		in_download = 1
		next
	}

	in_download && $0 == "refresh_subscription_cache() {" {
		in_download = 0
		print
		next
	}

	in_download {
		next
	}

	{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp" "$subscription_download_function"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp" "$subscription_download_function"
fi

if ! grep -Fq 'reduce .[] as $item' "$target" 2>/dev/null; then
	awk '
	$0 == "    awk '\''!seen[$0]++'\'' \"$merged_skipped_links_file\" > \"$deduped_skipped_links_file\"" {
		print "    jq -c -s '\''reduce .[] as $item ([]; if any(.[]; .id == $item.id) then . else . + [$item] end) | .[]'\'' \\"
		print "        \"$merged_skipped_links_file\" > \"$deduped_skipped_links_file\""
		next
	}

	$0 == "    awk '\''!seen[$0]++'\'' \"$merged_items_file\" > \"$deduped_items_file\"" {
		print "    jq -c -s '\''reduce .[] as $item ([]; if any(.[]; .id == $item.id) then . else . + [$item] end) | .[]'\'' \\"
		print "        \"$merged_items_file\" > \"$deduped_items_file\""
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

if [ -f "$helper_target" ] && ! grep -q "curl -fsSL --connect-timeout 10 -m 30" "$helper_target" 2>/dev/null; then
	awk '
	BEGIN { in_download = 0 }

	$0 == "download_to_file() {" {
		print "download_to_file() {"
		print "    local url=\"$1\""
		print "    local filepath=\"$2\""
		print "    local http_proxy_address=\"$3\""
		print "    local retries=\"${4:-3}\""
		print "    local wait=\"${5:-2}\""
		print "    local attempt"
		print ""
		print "    for attempt in $(seq 1 \"$retries\"); do"
		print "        rm -f \"$filepath\""
		print "        if [ -n \"$http_proxy_address\" ]; then"
		print "            if command -v curl > /dev/null 2>&1; then"
		print "                curl -fsSL -x \"http://$http_proxy_address\" --connect-timeout 10 -m 30 -o \"$filepath\" \"$url\" &&"
		print "                    [ -s \"$filepath\" ] && return 0"
		print "            else"
		print "                http_proxy=\"http://$http_proxy_address\" https_proxy=\"http://$http_proxy_address\" \\"
		print "                    wget -T 30 -t 1 -O \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print "        else"
		print "            if command -v curl > /dev/null 2>&1; then"
		print "                curl -fsSL --connect-timeout 10 -m 30 -o \"$filepath\" \"$url\" &&"
		print "                    [ -s \"$filepath\" ] && return 0"
		print "            else"
		print "                wget -T 30 -t 1 -O \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print "        fi"
		print ""
		print "        log \"Attempt $attempt/$retries to download $url failed\" \"warn\""
		print "        sleep \"$wait\""
		print "    done"
		print ""
		print "    return 1"
		print "}"
		in_download = 1
		next
	}

	in_download && $0 == "# Converts Windows-style line endings (CRLF) to Unix-style (LF)" {
		in_download = 0
		print ""
		print
		next
	}

	in_download {
		next
	}

	{ print }
	' "$helper_target" > "$helper_tmp" || {
		rm -f "$helper_tmp"
		exit 1
	}
	cat "$helper_tmp" > "$helper_target"
	rm -f "$helper_tmp"
fi

chmod 755 "$target"
[ -f "$helper_target" ] && chmod 644 "$helper_target"
