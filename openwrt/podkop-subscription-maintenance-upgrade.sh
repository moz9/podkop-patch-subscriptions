#!/bin/sh
set -eu

target="${PODKOP_MAINTENANCE_TARGET:-/usr/bin/podkop}"
tmp="${target}.tmp.$$"
helper_target="${PODKOP_MAINTENANCE_HELPERS_TARGET:-/usr/lib/podkop/helpers.sh}"
helper_tmp="${helper_target}.tmp.$$"

if ! grep -q "get_subscription_items_cached" "$target" 2>/dev/null; then
	exit 0
fi

sed -i 's#PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /etc/init.d/podkop reload#PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload#g' "$target"

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
	print "        if ! PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload > /dev/null 2>&1; then"
	next
}

$0 == "    /etc/init.d/podkop reload > /dev/null 2>&1" {
	print "    PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload > /dev/null 2>&1"
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

if ! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS:-4' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT:-15' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3' "$target" 2>/dev/null ||
	! grep -q "^get_subscription_benchmark_attempts()" "$target" 2>/dev/null; then
	benchmark_helpers="$(mktemp)"
	cat > "$benchmark_helpers" <<'BENCHMARK_HELPERS_EOF'
get_subscription_benchmark_port() {
    echo "42080"
}

get_subscription_benchmark_bytes() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608}"
}

get_subscription_benchmark_streams() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS:-4}"
}

get_subscription_benchmark_timeout() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT:-15}"
}

get_subscription_benchmark_warmup_bytes() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0}"
}

get_subscription_benchmark_attempts() {
    echo "${PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3}"
}
BENCHMARK_HELPERS_EOF

	awk -v helpers="$benchmark_helpers" '
	BEGIN {
		inserted = 0
		skip = 0
	}

	$0 ~ /^get_subscription_benchmark_(port|bytes|streams|timeout|warmup_bytes|attempts)\(\) \{$/ {
		skip = 1
		next
	}

	skip && $0 == "}" {
		skip = 0
		next
	}

	skip {
		next
	}

	!inserted && ($0 == "subscription_runtime_busy() {" || $0 == "subscription_speedtest() {") {
		while ((getline line < helpers) > 0) {
			print line
		}
		print ""
		inserted = 1
	}

	{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp" "$benchmark_helpers"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp" "$benchmark_helpers"
fi

if ! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS:-4' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT:-15' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0' "$target" 2>/dev/null ||
	! grep -q 'PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3' "$target" 2>/dev/null ||
	! grep -q -- '--connect-timeout 4' "$target" 2>/dev/null ||
	! grep -q 'time_starttransfer' "$target" 2>/dev/null ||
	! grep -q 'local only_id="$2"' "$target" 2>/dev/null ||
	! grep -q "exit 130' INT TERM HUP" "$target" 2>/dev/null ||
	! grep -q "clash_ready" "$target" 2>/dev/null ||
	! grep -q "service_busy" "$target" 2>/dev/null ||
	! grep -q "clash_api_wait_proxy_now" "$target" 2>/dev/null ||
	! grep -q "restore_proxy" "$target" 2>/dev/null; then
	speedtest_function="$(mktemp)"
	cat > "$speedtest_function" <<'SPEEDTEST_EOF'
subscription_speedtest() {
    local section="$1"
    local only_id="$2"
    local items_cache_path active_items_file results_file clash_url auth_header selector_tag urltest_tag original_proxy restore_proxy \
        original_mixed_enabled original_mixed_port mixed_port mixed_changed mixed_address benchmark_url \
        warmup_url benchmark_bytes benchmark_streams benchmark_timeout warmup_bytes benchmark_attempts min_size_download item_json id name tag index \
        output output_dir stream stream_file bytes_per_second time_total time_starttransfer transfer_time size_download http_code success_http_code results_json attempt best_bytes_per_second \
        best_time_total best_size_download best_http_code clash_ready completed_streams total_size max_time cache_buster

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

    if ! subscription_action_lock_acquire "speedtest"; then
        echo '{"success":false,"error":"service_busy"}'
        return 1
    fi
    trap 'subscription_action_lock_release' EXIT INT TERM

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
    if [ -n "$only_id" ]; then
        jq -c --arg id "$only_id" \
            '[.[] | select(.supported == true and .enabled == true)] | to_entries[] | select(.value.id == $id) | .value + {activeIndex:(.key + 1)}' \
            "$items_cache_path" > "$active_items_file"
    else
        jq -c '[.[] | select(.supported == true and .enabled == true)] | to_entries[] | .value + {activeIndex:(.key + 1)}' \
            "$items_cache_path" > "$active_items_file"
    fi

    if [ ! -s "$active_items_file" ]; then
        rm -f "$active_items_file" "$results_file"
        if [ -n "$only_id" ]; then
            echo '{"success":false,"error":"subscription_link_not_available"}'
        else
            echo '{"success":false,"error":"no_enabled_links"}'
        fi
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
    trap 'clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$restore_proxy" > /dev/null 2>&1 || clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$original_proxy" > /dev/null 2>&1 || true; subscription_speedtest_restore_mixed_proxy "$section" "$original_mixed_enabled" "$original_mixed_port" "$mixed_changed" > /dev/null 2>&1; rm -f "$active_items_file" "$results_file"; subscription_action_lock_release; exit 130' INT TERM HUP

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

        if ! PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload > /dev/null 2>&1; then
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

    benchmark_bytes="$(get_subscription_benchmark_bytes)"
    benchmark_streams="$(get_subscription_benchmark_streams)"
    benchmark_timeout="$(get_subscription_benchmark_timeout)"
    warmup_bytes="$(get_subscription_benchmark_warmup_bytes)"
    benchmark_attempts="$(get_subscription_benchmark_attempts)"
    case "$benchmark_bytes" in ''|*[!0-9]*) benchmark_bytes=8388608 ;; esac
    case "$benchmark_streams" in ''|*[!0-9]*) benchmark_streams=4 ;; esac
    case "$benchmark_timeout" in ''|*[!0-9]*) benchmark_timeout=15 ;; esac
    case "$warmup_bytes" in ''|*[!0-9]*) warmup_bytes=0 ;; esac
    case "$benchmark_attempts" in ''|*[!0-9]*) benchmark_attempts=3 ;; esac
    [ "$benchmark_bytes" -gt 0 ] || benchmark_bytes=8388608
    [ "$benchmark_streams" -gt 0 ] || benchmark_streams=1
    [ "$benchmark_streams" -le 8 ] || benchmark_streams=8
    [ "$benchmark_timeout" -ge 5 ] || benchmark_timeout=5
    [ "$benchmark_attempts" -gt 0 ] || benchmark_attempts=3
    min_size_download=$((benchmark_bytes * 9 / 10))
    benchmark_url="https://speed.cloudflare.com/__down?bytes=$benchmark_bytes"
    warmup_url="https://speed.cloudflare.com/__down?bytes=$warmup_bytes"
    index=1
    while IFS= read -r item_json || [ -n "$item_json" ]; do
        [ -n "$item_json" ] || continue

        id="$(echo "$item_json" | jq -r '.id')"
        name="$(echo "$item_json" | jq -r '.name // ""')"
        index="$(echo "$item_json" | jq -r '.activeIndex')"
        tag="$(get_outbound_tag_by_section "$section-$index")"

        if ! clash_api_set_group_proxy_raw "$clash_url" "$auth_header" "$selector_tag" "$tag"; then
            subscription_speedtest_result_error "$id" "$tag" "$name" "select_failed" >> "$results_file"
            index=$((index + 1))
            continue
        fi

        if [ "$warmup_bytes" -gt 0 ]; then
            curl -L -s -o /dev/null \
                -x "http://$mixed_address:$mixed_port" \
                --connect-timeout 3 \
                -m 4 \
                "$warmup_url" > /dev/null 2>&1 || true
        fi

        best_bytes_per_second=0
        best_time_total=0
        best_size_download=0
        best_http_code=0
        for attempt in $(seq 1 "$benchmark_attempts"); do
            output_dir="$(mktemp -d)" || continue
            cache_buster="$(date +%s)-$$-$attempt"
            stream=1
            while [ "$stream" -le "$benchmark_streams" ]; do
                stream_file="$output_dir/$stream.out"
                curl -L -s -o /dev/null \
                    -x "http://$mixed_address:$mixed_port" \
                    --connect-timeout 4 \
                    -m "$benchmark_timeout" \
                    -w '%{time_total} %{time_starttransfer} %{size_download} %{http_code}' \
                    "$benchmark_url&stream=$stream&r=$cache_buster" > "$stream_file" 2> /dev/null &
                stream=$((stream + 1))
            done
            wait

            completed_streams=0
            total_size=0
            max_time=0
            success_http_code=0
            stream=1
            while [ "$stream" -le "$benchmark_streams" ]; do
                stream_file="$output_dir/$stream.out"
                output="$(cat "$stream_file" 2> /dev/null)"
                time_total="$(echo "$output" | awk '{print ($1 == "" ? 0 : $1)}')"
                time_starttransfer="$(echo "$output" | awk '{print ($2 == "" ? 0 : $2)}')"
                size_download="$(echo "$output" | awk '{printf "%d", $3}')"
                http_code="$(echo "$output" | awk '{printf "%d", $4}')"
                transfer_time="$(
                    awk -v total="$time_total" -v start="$time_starttransfer" '
                        BEGIN {
                            transfer = total - start
                            if (transfer <= 0) {
                                transfer = total
                            }
                            print transfer
                        }
                    '
                )"

                if [ "${size_download:-0}" -ge "$min_size_download" ] &&
                    [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 400 ]; then
                    completed_streams=$((completed_streams + 1))
                    total_size=$((total_size + size_download))
                    success_http_code="$http_code"
                    max_time="$(
                        awk -v current="$max_time" -v candidate="$transfer_time" '
                            BEGIN {
                                if (candidate > current) {
                                    print candidate
                                } else {
                                    print current
                                }
                            }
                        '
                    )"
                fi

                stream=$((stream + 1))
            done
            rm -rf "$output_dir"

            bytes_per_second="$(
                awk -v size="$total_size" -v total="$max_time" '
                    BEGIN {
                        if (total > 0) {
                            printf "%d", size / total
                        } else {
                            printf "0"
                        }
                    }
                '
            )"

            if [ "${bytes_per_second:-0}" -gt "$best_bytes_per_second" ] &&
                [ "${completed_streams:-0}" -gt 0 ]; then
                best_bytes_per_second="${bytes_per_second:-0}"
                best_time_total="${max_time:-0}"
                best_size_download="${total_size:-0}"
                best_http_code="${success_http_code:-0}"
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

if ! grep -Fq 'patch_update_download_v2' "$target" 2>/dev/null; then
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
patch_update_download_v2=1

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
fi

if [ "$download_ok" -ne 1 ] && command -v wget > /dev/null 2>&1; then
    if wget -T 30 -O "$tmp" "$install_url" > "$log_file" 2>&1; then
        download_ok=1
    else
        for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
            if wget -T 30 --no-check-certificate --header="Host: raw.githubusercontent.com" \
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

if ! grep -Fq 'Subscription download via service proxy failed; trying direct download' "$target" 2>/dev/null; then
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
        if [ -n "$http_proxy_address" ]; then
            if command -v curl > /dev/null 2>&1; then
                curl -fsSL -x "http://$http_proxy_address" --connect-timeout 10 -m 30 -o "$filepath" "$url" &&
                    [ -s "$filepath" ] && return 0
            fi
            if command -v wget > /dev/null 2>&1; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    wget -T 30 -O "$filepath" "$url" && [ -s "$filepath" ] && return 0
            fi
            rm -f "$filepath"
            log "Subscription download via service proxy failed; trying direct download" "debug"
        fi
        if command -v curl > /dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 -m 30 -o "$filepath" "$url" && [ -s "$filepath" ] && return 0
        elif command -v wget > /dev/null 2>&1; then
            wget -T 30 -O "$filepath" "$url" && [ -s "$filepath" ] && return 0
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

if ! grep -Fq 'subscription sources that could not be downloaded' "$target" 2>/dev/null; then
	awk '
	BEGIN {
		in_download_fail = 0
		skip_failed_block = 0
		in_skipped_sources_block = 0
	}

	$0 == "        if ! download_subscription_to_file \"$subscription_url\" \"$tmpfile\" \"$http_proxy_address\"; then" {
		in_download_fail = 1
		print
		next
	}

	in_download_fail && $0 == "            break" {
		print "            source_index=$((source_index + 1))"
		print "            continue"
		next
	}

	in_download_fail && $0 == "        fi" {
		in_download_fail = 0
		print
		next
	}

	$0 == "    if [ \"$failed_sources\" -gt 0 ]; then" {
		skip_failed_block = 1
		next
	}

	skip_failed_block && $0 == "" {
		skip_failed_block = 0
		print
		next
	}

	skip_failed_block {
		next
	}

	$0 == "    if [ \"$skipped_sources\" -gt 0 ]; then" {
		in_skipped_sources_block = 1
		print
		next
	}

	in_skipped_sources_block && $0 == "    fi" {
		in_skipped_sources_block = 0
		print
		print ""
		print "    if [ \"$failed_sources\" -gt 0 ]; then"
		print "        log \"Skipped $failed_sources subscription sources that could not be downloaded for section '\''$section'\''\" \"warn\""
		print "    fi"
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

if ! grep -q "subscription_action_lock_file" "$target" 2>/dev/null; then
	awk '
	$0 == "# sing-box funcs" {
		print "subscription_action_lock_file() {"
		print "    echo \"/tmp/podkop-subscription-action.lock\""
		print "}"
		print ""
		print "subscription_action_lock_pid_alive() {"
		print "    local pid=\"$1\""
		print ""
		print "    [ -n \"$pid\" ] || return 1"
		print "    case \"$pid\" in"
		print "    *[!0-9]*)"
		print "        return 1"
		print "        ;;"
		print "    esac"
		print ""
		print "    [ -d \"/proc/$pid\" ]"
		print "}"
		print ""
		print "subscription_action_lock_busy() {"
		print "    local lock_file pid"
		print ""
		print "    lock_file=\"$(subscription_action_lock_file)\""
		print "    [ -s \"$lock_file\" ] || return 1"
		print ""
		print "    pid=\"$(awk '\''NR == 1 {print $1}'\'' \"$lock_file\" 2> /dev/null)\""
		print "    if subscription_action_lock_pid_alive \"$pid\"; then"
		print "        return 0"
		print "    fi"
		print ""
		print "    rm -f \"$lock_file\""
		print "    return 1"
		print "}"
		print ""
		print "subscription_action_lock_acquire() {"
		print "    local action=\"$1\""
		print "    local lock_file"
		print ""
		print "    lock_file=\"$(subscription_action_lock_file)\""
		print "    if subscription_action_lock_busy; then"
		print "        return 1"
		print "    fi"
		print ""
		print "    printf '\''%s %s %s\\n'\'' \"$$\" \"$action\" \"$(date +%s 2> /dev/null || date)\" > \"$lock_file\""
		print "}"
		print ""
		print "subscription_action_lock_release() {"
		print "    local lock_file pid"
		print ""
		print "    lock_file=\"$(subscription_action_lock_file)\""
		print "    [ -s \"$lock_file\" ] || return 0"
		print ""
		print "    pid=\"$(awk '\''NR == 1 {print $1}'\'' \"$lock_file\" 2> /dev/null)\""
		print "    [ \"$pid\" = \"$$\" ] && rm -f \"$lock_file\""
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

if ! grep -q "Subscription runtime is busy, skipping subscription update" "$target" 2>/dev/null; then
	awk '
	$0 == "    SUBSCRIPTION_FAILED_SECTIONS=0" {
		print
		print ""
		print "    if subscription_runtime_busy; then"
		print "        echolog \"Subscription runtime is busy, skipping subscription update\""
		print "        return 0"
		print "    fi"
		print ""
		print "    if ! subscription_action_lock_acquire \"subscription_update\"; then"
		print "        echolog \"Subscription runtime is busy, skipping subscription update\""
		print "        return 0"
		print "    fi"
		print "    trap '\''subscription_action_lock_release'\'' EXIT INT TERM"
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

if grep -q "Subscription cache changed, reloading podkop..." "$target" 2>/dev/null; then
	awk '
	prev == "        echolog \"Subscription cache changed, reloading podkop...\"" && $0 == "        /etc/init.d/podkop reload" {
		print "        PODKOP_SUBSCRIPTION_CACHE_ONLY=1 PODKOP_SKIP_LIST_UPDATE=1 /usr/bin/podkop reload"
		prev = $0
		next
	}

	{ print; prev = $0 }
	' "$target" > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp"
fi

if ! grep -q "subscription_action_lock_busy; then" "$target" 2>/dev/null; then
	awk '
	$0 == "    local status_file state" {
		print
		print ""
		print "    if subscription_action_lock_busy; then"
		print "        return 0"
		print "    fi"
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

if ! grep -q "subscription_action_lock_acquire \"speedtest\"" "$target" 2>/dev/null; then
	awk '
	BEGIN { in_speedtest = 0; after_busy = 0 }

	$0 == "subscription_speedtest() {" {
		in_speedtest = 1
		print
		next
	}

	in_speedtest && $0 == "    if subscription_runtime_busy; then" {
		after_busy = 1
		print
		next
	}

	in_speedtest && after_busy && $0 == "    fi" {
		print
		print ""
		print "    if ! subscription_action_lock_acquire \"speedtest\"; then"
		print "        echo '\''{\"success\":false,\"error\":\"service_busy\"}'\''"
		print "        return 1"
		print "    fi"
		print "    trap '\''subscription_action_lock_release'\'' EXIT INT TERM"
		after_busy = 0
		next
	}

	in_speedtest && $0 == "subscription_patch_update_status_file() {" {
		in_speedtest = 0
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

if ! grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608" "$target" 2>/dev/null ||
	! grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_STREAMS:-4" "$target" 2>/dev/null ||
	! grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_TIMEOUT:-15" "$target" 2>/dev/null ||
	! grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0" "$target" 2>/dev/null ||
	! grep -q "PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3" "$target" 2>/dev/null ||
	! grep -q -- "--connect-timeout 4" "$target" 2>/dev/null ||
	! grep -q "time_starttransfer" "$target" 2>/dev/null ||
	! grep -q 'local only_id="$2"' "$target" 2>/dev/null ||
	! grep -q "exit 130' INT TERM HUP" "$target" 2>/dev/null; then
	sed -i \
		-e 's#PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-[0-9][0-9]*#PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608#g' \
		-e 's#PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-[0-9][0-9]*#PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0#g' \
		-e 's#echo "8388608"#echo "${PODKOP_SUBSCRIPTION_BENCHMARK_BYTES:-8388608}"#' \
		-e 's#echo "262144"#echo "${PODKOP_SUBSCRIPTION_BENCHMARK_WARMUP_BYTES:-0}"#' \
		-e 's#echo "2"#echo "${PODKOP_SUBSCRIPTION_BENCHMARK_ATTEMPTS:-3}"#' \
		-e 's#benchmark_bytes="8388608"#benchmark_bytes="$(get_subscription_benchmark_bytes)"#' \
		-e 's#warmup_bytes="262144"#warmup_bytes="$(get_subscription_benchmark_warmup_bytes)"#' \
		-e 's#benchmark_attempts="2"#benchmark_attempts="$(get_subscription_benchmark_attempts)"#' \
		-e 's#\[ "$mixed_changed" -eq 1 \]#\[ "${mixed_changed:-0}" -eq 1 \]#' \
		-e 's#--connect-timeout 6#--connect-timeout 3#g' \
		-e 's#--connect-timeout 8#--connect-timeout 4#g' \
		-e 's#-m 10#-m 4#g' \
		-e 's#-m 35#-m 6#g' \
		-e 's#-m 12#-m 6#g' \
		"$target"

	if ! grep -q "exit 130' INT TERM HUP" "$target" 2>/dev/null; then
		awk '
		$0 == "    mixed_changed=0" {
			print
			print "    trap '\''clash_api_set_group_proxy_raw \"$clash_url\" \"$auth_header\" \"$selector_tag\" \"$restore_proxy\" > /dev/null 2>&1 || clash_api_set_group_proxy_raw \"$clash_url\" \"$auth_header\" \"$selector_tag\" \"$original_proxy\" > /dev/null 2>&1 || true; subscription_speedtest_restore_mixed_proxy \"$section\" \"$original_mixed_enabled\" \"$original_mixed_port\" \"$mixed_changed\" > /dev/null 2>&1; rm -f \"$active_items_file\" \"$results_file\"; subscription_action_lock_release; exit 130'\'' INT TERM HUP"
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
fi

if grep -q 'subscription_speedtest "$2"' "$target" 2>/dev/null &&
	! grep -q 'subscription_speedtest "$2" "$3"' "$target" 2>/dev/null; then
	sed -i 's#subscription_speedtest "$2"#subscription_speedtest "$2" "$3"#' "$target"
fi

if ! grep -q '^subscription_speedtest_status_file()' "$target" 2>/dev/null; then
	async_file="$(mktemp)"
	cat > "$async_file" << 'ASYNC_EOF'
subscription_speedtest_status_file() {
    echo "/tmp/podkop-subscriptions-speedtest.json"
}

subscription_speedtest_start() {
    local section="$1"
    local item_id="$2"
    local status_file runner state pid updated_at

    if [ -z "$section" ] || [ -z "$item_id" ]; then
        echo '{"success":false,"error":"section_and_item_required"}'
        return 1
    fi

    status_file="$(subscription_speedtest_status_file)"
    if [ -s "$status_file" ]; then
        state="$(jq -r '.state // ""' "$status_file" 2> /dev/null)"
        pid="$(jq -r '.pid // ""' "$status_file" 2> /dev/null)"
        if [ "$state" = "running" ] && subscription_action_lock_pid_alive "$pid"; then
            echo '{"success":false,"error":"service_busy"}'
            return 1
        fi
    fi

    updated_at="$(date -Iseconds 2> /dev/null || date)"
    jq -cn --arg state "running" --arg message "speedtest_running" \
        --arg section "$section" --arg itemId "$item_id" \
        --arg updatedAt "$updated_at" --argjson pid "$$" \
        --arg logTail "" \
        '{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail}' \
        > "$status_file"

    runner="/tmp/podkop-subscriptions-speedtest-runner.sh"
    cat > "$runner" << 'EOF'
#!/bin/ash
status_file="/tmp/podkop-subscriptions-speedtest.json"
section="$1"
item_id="$2"

write_status() {
    local state="$1"
    local message="$2"
    local result_file="$3"
    local log_tail="$4"
    local updated_at

    updated_at="$(date -Iseconds 2> /dev/null || date)"

    if [ -n "$result_file" ] && [ -s "$result_file" ]; then
        jq -cn --arg state "$state" --arg message "$message" \
            --arg section "$section" --arg itemId "$item_id" \
            --arg updatedAt "$updated_at" --argjson pid "$$" \
            --arg logTail "$log_tail" --slurpfile result "$result_file" \
            '{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail, result:($result[0] // null)}' \
            > "$status_file"
    else
        jq -cn --arg state "$state" --arg message "$message" \
            --arg section "$section" --arg itemId "$item_id" \
            --arg updatedAt "$updated_at" --argjson pid "$$" \
            --arg logTail "$log_tail" \
            '{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail}' \
            > "$status_file"
    fi
}

result_file="$(mktemp)"
output_file="$(mktemp)"

write_status "running" "speedtest_running" "" ""

/usr/bin/podkop subscription_speedtest "$section" "$item_id" > "$output_file" 2>&1
rc="$?"

if [ "$rc" -eq 0 ] && jq -e '.success == true' "$output_file" > /dev/null 2>&1; then
    cp "$output_file" "$result_file"
    write_status "success" "speedtest_success" "$result_file" ""
else
    message="speedtest_failed"
    if jq -e '.error' "$output_file" > /dev/null 2>&1; then
        message="$(jq -r '.error // "speedtest_failed"' "$output_file" 2> /dev/null)"
    fi
    write_status "error" "$message" "" "$(tail -n 20 "$output_file" 2> /dev/null)"
    rm -f "$result_file" "$output_file"
    exit 1
fi

rm -f "$result_file" "$output_file"
EOF

    chmod +x "$runner"
    if command -v start-stop-daemon > /dev/null 2>&1; then
        start-stop-daemon -S -b -x "$runner" -- "$section" "$item_id" > /dev/null 2>&1
    elif command -v setsid > /dev/null 2>&1; then
        setsid "$runner" "$section" "$item_id" < /dev/null > /dev/null 2>&1 &
    else
        "$runner" "$section" "$item_id" < /dev/null > /dev/null 2>&1 &
    fi

    echo '{"success":true,"started":true}'
}

get_subscription_speedtest_status() {
    local status_file

    status_file="$(subscription_speedtest_status_file)"
    if [ -s "$status_file" ]; then
        cat "$status_file"
    else
        echo '{"state":"idle","message":"","section":"","itemId":"","updatedAt":"","logTail":""}'
    fi
}
ASYNC_EOF

	awk -v insert_file="$async_file" '
		$0 == "show_help() {" && ! inserted {
			while ((getline line < insert_file) > 0) {
				print line
			}
			close(insert_file)
			print ""
			inserted = 1
		}
		{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp" "$async_file"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp" "$async_file"
fi

if grep -q '^subscription_speedtest_start()' "$target" 2>/dev/null &&
	! grep -q -- '--arg state "running" --arg message "speedtest_running"' "$target" 2>/dev/null; then
	sed -i 's#local status_file runner state pid$#local status_file runner state pid updated_at#' "$target"
	awk '
		/^subscription_speedtest_start\(\) \{/ {
			in_speedtest_start = 1
		}

		in_speedtest_start && $0 == "    runner=\"/tmp/podkop-subscriptions-speedtest-runner.sh\"" && ! inserted {
			print "    updated_at=\"$(date -Iseconds 2> /dev/null || date)\""
			print "    jq -cn --arg state \"running\" --arg message \"speedtest_running\" \\"
			print "        --arg section \"$section\" --arg itemId \"$item_id\" \\"
			print "        --arg updatedAt \"$updated_at\" --argjson pid \"$$\" \\"
			print "        --arg logTail \"\" \\"
			print "        '\''{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail}'\'' \\"
			print "        > \"$status_file\""
			print ""
			inserted = 1
		}

		/^get_subscription_speedtest_status\(\) \{/ {
			in_speedtest_start = 0
		}

		{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp"
fi

if ! grep -q '^subscription_speedtest_stop()' "$target" 2>/dev/null ||
	! grep -q '^subscription_speedtest_restore_state_file()' "$target" 2>/dev/null; then
	async_file="$(mktemp)"
	cat > "$async_file" << 'ASYNC_CURRENT_EOF'
subscription_speedtest_status_file() {
    echo "/tmp/podkop-subscriptions-speedtest.json"
}

subscription_speedtest_restore_state_file() {
    echo "/tmp/podkop-subscriptions-speedtest-restore.json"
}

subscription_speedtest_write_status() {
    local state="$1"
    local message="$2"
    local section="$3"
    local item_id="$4"
    local pid="$5"
    local status_file updated_at

    status_file="$(subscription_speedtest_status_file)"
    updated_at="$(date -Iseconds 2> /dev/null || date)"
    jq -cn --arg state "$state" --arg message "$message" \
        --arg section "$section" --arg itemId "$item_id" \
        --arg updatedAt "$updated_at" --argjson pid "${pid:-0}" \
        --arg logTail "" \
        '{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail}' \
        > "$status_file"
}

subscription_speedtest_start() {
    local section="$1"
    local item_id="$2"
    local status_file restore_file runner state pid original_mixed_enabled original_mixed_port

    if [ -z "$section" ] || [ -z "$item_id" ]; then
        echo '{"success":false,"error":"section_and_item_required"}'
        return 1
    fi

    status_file="$(subscription_speedtest_status_file)"
    if [ -s "$status_file" ]; then
        state="$(jq -r '.state // ""' "$status_file" 2> /dev/null)"
        pid="$(jq -r '.pid // ""' "$status_file" 2> /dev/null)"
        if [ "$state" = "running" ] && subscription_action_lock_pid_alive "$pid"; then
            echo '{"success":false,"error":"service_busy"}'
            return 1
        fi
    fi

    subscription_speedtest_write_status "running" "speedtest_running" "$section" "$item_id" "$$"

    restore_file="$(subscription_speedtest_restore_state_file)"
    config_get original_mixed_enabled "$section" "mixed_proxy_enabled"
    config_get original_mixed_port "$section" "mixed_proxy_port"
    jq -cn --arg section "$section" \
        --arg originalMixedEnabled "$original_mixed_enabled" \
        --arg originalMixedPort "$original_mixed_port" \
        '{section:$section, originalMixedEnabled:$originalMixedEnabled, originalMixedPort:$originalMixedPort}' \
        > "$restore_file"

    runner="/tmp/podkop-subscriptions-speedtest-runner.sh"
    cat > "$runner" << 'EOF'
#!/bin/ash
status_file="/tmp/podkop-subscriptions-speedtest.json"
restore_file="/tmp/podkop-subscriptions-speedtest-restore.json"
section="$1"
item_id="$2"

write_status() {
    local state="$1"
    local message="$2"
    local result_file="$3"
    local log_tail="$4"
    local updated_at

    updated_at="$(date -Iseconds 2> /dev/null || date)"

    if [ -n "$result_file" ] && [ -s "$result_file" ]; then
        jq -cn --arg state "$state" --arg message "$message" \
            --arg section "$section" --arg itemId "$item_id" \
            --arg updatedAt "$updated_at" --argjson pid "$$" \
            --arg logTail "$log_tail" --slurpfile result "$result_file" \
            '{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail, result:($result[0] // null)}' \
            > "$status_file"
    else
        jq -cn --arg state "$state" --arg message "$message" \
            --arg section "$section" --arg itemId "$item_id" \
            --arg updatedAt "$updated_at" --argjson pid "$$" \
            --arg logTail "$log_tail" \
            '{state:$state, message:$message, section:$section, itemId:$itemId, updatedAt:$updatedAt, pid:$pid, logTail:$logTail}' \
            > "$status_file"
    fi
}

result_file="$(mktemp)"
output_file="$(mktemp)"

write_status "running" "speedtest_running" "" ""

/usr/bin/podkop subscription_speedtest "$section" "$item_id" > "$output_file" 2>&1
rc="$?"

if [ "$rc" -eq 0 ] && jq -e '.success == true' "$output_file" > /dev/null 2>&1; then
    cp "$output_file" "$result_file"
    write_status "success" "speedtest_success" "$result_file" ""
else
    message="speedtest_failed"
    if jq -e '.error' "$output_file" > /dev/null 2>&1; then
        message="$(jq -r '.error // "speedtest_failed"' "$output_file" 2> /dev/null)"
    fi
    write_status "error" "$message" "" "$(tail -n 20 "$output_file" 2> /dev/null)"
    rm -f "$result_file" "$output_file" "$restore_file"
    exit 1
fi

rm -f "$result_file" "$output_file" "$restore_file"
EOF

    chmod +x "$runner"
    if command -v start-stop-daemon > /dev/null 2>&1; then
        start-stop-daemon -S -b -x "$runner" -- "$section" "$item_id" > /dev/null 2>&1
    elif command -v setsid > /dev/null 2>&1; then
        setsid "$runner" "$section" "$item_id" < /dev/null > /dev/null 2>&1 &
    else
        "$runner" "$section" "$item_id" < /dev/null > /dev/null 2>&1 &
    fi

    echo '{"success":true,"started":true}'
}

subscription_speedtest_stop() {
    local status_file restore_file state pid section item_id restore_section original_mixed_enabled original_mixed_port

    status_file="$(subscription_speedtest_status_file)"
    restore_file="$(subscription_speedtest_restore_state_file)"
    if [ ! -s "$status_file" ]; then
        echo '{"success":true,"stopped":false}'
        return 0
    fi

    state="$(jq -r '.state // ""' "$status_file" 2> /dev/null)"
    pid="$(jq -r '.pid // ""' "$status_file" 2> /dev/null)"
    section="$(jq -r '.section // ""' "$status_file" 2> /dev/null)"
    item_id="$(jq -r '.itemId // ""' "$status_file" 2> /dev/null)"

    if [ "$state" = "running" ] && subscription_action_lock_pid_alive "$pid"; then
        kill_process_tree "$pid" > /dev/null 2>&1 || true
        sleep 1
    fi

    if [ -s "$restore_file" ]; then
        restore_section="$(jq -r '.section // ""' "$restore_file" 2> /dev/null)"
        original_mixed_enabled="$(jq -r '.originalMixedEnabled // ""' "$restore_file" 2> /dev/null)"
        original_mixed_port="$(jq -r '.originalMixedPort // ""' "$restore_file" 2> /dev/null)"
        if [ -n "$restore_section" ]; then
            subscription_speedtest_restore_mixed_proxy "$restore_section" "$original_mixed_enabled" "$original_mixed_port" 1 > /dev/null 2>&1 || true
        fi
        rm -f "$restore_file"
    elif [ -n "$section" ]; then
        subscription_speedtest_restore_mixed_proxy "$section" "" "" 1 > /dev/null 2>&1 || true
    fi

    subscription_speedtest_write_status "cancelled" "speedtest_cancelled" "$section" "$item_id" "0"
    echo '{"success":true,"stopped":true}'
}

get_subscription_speedtest_status() {
    local status_file

    status_file="$(subscription_speedtest_status_file)"
    if [ -s "$status_file" ]; then
        cat "$status_file"
    else
        echo '{"state":"idle","message":"","section":"","itemId":"","updatedAt":"","logTail":""}'
    fi
}
ASYNC_CURRENT_EOF

	if grep -q '^subscription_patch_update_status_file()' "$target" 2>/dev/null; then
		awk -v insert_file="$async_file" '
			$0 == "subscription_speedtest_status_file() {" && ! inserted {
				while ((getline line < insert_file) > 0) {
					print line
				}
				close(insert_file)
				inserted = 1
				skip = 1
				next
			}

			skip && $0 == "subscription_patch_update_status_file() {" {
				skip = 0
				print
				next
			}

			!skip { print }
		' "$target" > "$tmp" || {
			rm -f "$tmp" "$async_file"
			exit 1
		}
	else
		awk -v insert_file="$async_file" '
			$0 == "show_help() {" && ! inserted {
				while ((getline line < insert_file) > 0) {
					print line
				}
				close(insert_file)
				print ""
				inserted = 1
			}

			{ print }
		' "$target" > "$tmp" || {
			rm -f "$tmp" "$async_file"
			exit 1
		}
	fi
	cat "$tmp" > "$target"
	rm -f "$tmp" "$async_file"
fi

if ! grep -q '^subscription_speedtest_start)' "$target" 2>/dev/null; then
	awk '
		$0 == "    subscription_speedtest   Benchmark enabled subscription proxy items for a section" {
			print
			print "    subscription_speedtest_start"
			print "                            Start background benchmark for one subscription proxy item"
			print "    subscription_speedtest_stop"
			print "                            Stop background subscription benchmark"
			print "    get_subscription_speedtest_status"
			print "                            Show background subscription benchmark status"
			next
		}

		$0 == "subscription_patch_update)" && ! inserted {
			print "subscription_speedtest_start)"
			print "    subscription_speedtest_start \"$2\" \"$3\""
			print "    ;;"
			print "subscription_speedtest_stop)"
			print "    subscription_speedtest_stop"
			print "    ;;"
			print "get_subscription_speedtest_status)"
			print "    get_subscription_speedtest_status"
			print "    ;;"
			inserted = 1
		}

		{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp"
fi

if ! grep -q '^subscription_speedtest_stop)' "$target" 2>/dev/null; then
	awk '
		$0 == "get_subscription_speedtest_status)" && ! inserted {
			print "subscription_speedtest_stop)"
			print "    subscription_speedtest_stop"
			print "    ;;"
			inserted = 1
		}

		{ print }
	' "$target" > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	cat "$tmp" > "$target"
	rm -f "$tmp"
fi

if ! grep -q "restore_community_subnet_cache_v2" "$target" 2>/dev/null; then
	if grep -q '^COMMUNITY_SUBNET_CACHE_DIR=' "$target" 2>/dev/null; then
		sed -i 's#^COMMUNITY_SUBNET_CACHE_DIR=.*#COMMUNITY_SUBNET_CACHE_DIR="/etc/podkop/community-subnets"#' "$target"
	elif grep -q '^SUBSCRIPTION_CACHE_DIR=' "$target" 2>/dev/null; then
		awk '
		{
			print
			if ($0 ~ /^SUBSCRIPTION_CACHE_DIR=/) {
				print "COMMUNITY_SUBNET_CACHE_DIR=\"/etc/podkop/community-subnets\""
			}
		}
		' "$target" > "$tmp" || {
			rm -f "$tmp"
			exit 1
		}
		cat "$tmp" > "$target"
		rm -f "$tmp"
	fi

	if ! grep -q "community_subnet_lists_enabled()" "$target" 2>/dev/null; then
		functions_file="$(mktemp)"
		cat > "$functions_file" <<'SUBNET_CACHE_FUNCS_EOF'
get_community_subnet_cache_path() {
    local service="$1"

    echo "$COMMUNITY_SUBNET_CACHE_DIR/$service.lst"
}

cache_community_subnet_list() {
    local service="$1"
    local filepath="$2"
    local cache_path

    [ -s "$filepath" ] || return 0
    mkdir -p "$COMMUNITY_SUBNET_CACHE_DIR" || return 0
    cache_path="$(get_community_subnet_cache_path "$service")"
    cp "$filepath" "$cache_path" 2> /dev/null && chmod 600 "$cache_path" 2> /dev/null
}

restore_cached_community_subnet_list_handler() {
    local service="$1"
    local cache_path restore_community_subnet_cache_v2

    restore_community_subnet_cache_v2=1
    cache_path="$(get_community_subnet_cache_path "$service")"
    [ -s "$cache_path" ] || return 0

    if [ "$service" = "discord" ]; then
        if ! nft list set inet "$NFT_TABLE_NAME" "$NFT_DISCORD_SET_NAME" > /dev/null 2>&1; then
            nft_create_ipv4_set "$NFT_TABLE_NAME" "$NFT_DISCORD_SET_NAME"
        fi
        if ! nft list chain inet "$NFT_TABLE_NAME" mangle 2> /dev/null | grep -q "@$NFT_DISCORD_SET_NAME"; then
            nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr \
                "@$NFT_DISCORD_SET_NAME" udp dport '{ 19000-20000, 50000-65535 }' meta mark set "$NFT_FAKEIP_MARK" counter
        fi
        nft_add_set_elements_from_file_chunked "$cache_path" "$NFT_TABLE_NAME" "$NFT_DISCORD_SET_NAME"
    else
        nft_add_set_elements_from_file_chunked "$cache_path" "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME"
    fi
}

restore_cached_community_subnet_lists() {
    local section="$1"
    local community_lists

    config_get community_lists "$section" "community_lists"
    [ -n "$community_lists" ] || return 0

    config_list_foreach "$section" "community_lists" restore_cached_community_subnet_list_handler
}

community_subnet_lists_enabled_handler() {
    local section="$1"
    local community_lists service

    config_get community_lists "$section" "community_lists"
    for service in $community_lists; do
        case "$service" in
        twitter | meta | telegram | cloudflare | hetzner | ovh | digitalocean | cloudfront | discord | roblox)
            community_subnet_lists_found=1
            return 0
            ;;
        esac
    done
}

community_subnet_lists_enabled() {
    community_subnet_lists_found=0
    config_foreach community_subnet_lists_enabled_handler "section"
    [ "$community_subnet_lists_found" -eq 1 ]
}

nft_subnet_sets_have_elements() {
    nft list set inet "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" 2> /dev/null |
        grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' &&
        return 0

    nft list set inet "$NFT_TABLE_NAME" "$NFT_DISCORD_SET_NAME" 2> /dev/null |
        grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}'
}

SUBNET_CACHE_FUNCS_EOF
		awk -v funcs="$functions_file" '
		BEGIN {
			while ((getline line < funcs) > 0) {
				block = block line "\n"
			}
		}
		$0 == "# Main funcs" {
			printf "%s", block
			print
			next
		}
		{ print }
		' "$target" > "$tmp" || {
			rm -f "$tmp" "$functions_file"
			exit 1
		}
		cat "$tmp" > "$target"
		rm -f "$tmp" "$functions_file"
	fi

	if ! grep -q "Cached community subnet lists are unavailable" "$target" 2>/dev/null; then
		awk '
		$0 == "start_main() {" {
			print
			print "    local skip_list_update_started=0"
			next
		}

		$0 == "    create_nft_rules" {
			print
			print "    if [ \"$PODKOP_SKIP_LIST_UPDATE\" = \"1\" ]; then"
			print "        config_foreach restore_cached_community_subnet_lists \"section\""
			print "        if community_subnet_lists_enabled && ! nft_subnet_sets_have_elements; then"
			print "            log \"Cached community subnet lists are unavailable or empty, starting lists update in background\" \"warn\""
			print "            list_update &"
			print "            echo $! > /var/run/podkop_list_update.pid"
			print "            skip_list_update_started=1"
			print "        fi"
			print "    fi"
			next
		}

		$0 == "        log \"Skipping lists update for this reload\" \"debug\"" {
			print "        if [ \"$skip_list_update_started\" -eq 1 ]; then"
			print "            log \"Started lists update because cached subnet lists are missing\" \"debug\""
			print "        else"
			print "            log \"Skipping lists update for this reload\" \"debug\""
			print "        fi"
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

	if ! grep -q 'Download \$service list failed, using cached subnet list' "$target" 2>/dev/null; then
		awk '
		BEGIN { in_download_block = 0 }

		$0 == "    download_to_file \"$URL\" \"$tmpfile\" \"$http_proxy_address\"" {
			print "    if ! download_to_file \"$URL\" \"$tmpfile\" \"$http_proxy_address\" || [ ! -s \"$tmpfile\" ]; then"
			print "        local cache_path"
			print "        cache_path=\"$(get_community_subnet_cache_path \"$service\")\""
			print "        if [ -s \"$cache_path\" ]; then"
			print "            log \"Download $service list failed, using cached subnet list\" \"warn\""
			print "            cp \"$cache_path\" \"$tmpfile\""
			print "        else"
			print "            log \"Download $service list failed\" \"error\""
			print "            return 1"
			print "        fi"
			print "    else"
			print "        cache_community_subnet_list \"$service\" \"$tmpfile\""
			print "    fi"
			in_download_block = 1
			next
		}

		in_download_block && $0 == "    if [ \"$service\" = \"discord\" ]; then" {
			in_download_block = 0
			print
			next
		}

		in_download_block { next }

		{ print }
		' "$target" > "$tmp" || {
			rm -f "$tmp"
			exit 1
		}
		cat "$tmp" > "$target"
		rm -f "$tmp"
	fi
fi

if ! grep -q "patch_update_noop_v1" "$target" 2>/dev/null; then
	patch_update_function="$(mktemp)"
	cat > "$patch_update_function" <<'PATCH_UPDATE_EOF'
subscription_patch_update() {
    local status_file runner patch_update_start_stop_daemon_v1 patch_update_noop_v1

    patch_update_start_stop_daemon_v1=1
    patch_update_noop_v1=1

    status_file="$(subscription_patch_update_status_file)"
    runner="/tmp/podkop-subscriptions-patch-update-runner.sh"

    cat > "$runner" << 'EOF'
#!/bin/ash
status_file="/tmp/podkop-subscriptions-patch-update.json"
log_file="/tmp/podkop-subscriptions-patch-update.log"
patch_update_timeout_v1=1

write_status() {
    local state="$1"
    local message="$2"
    local log_tail="$3"
    jq -cn --arg state "$state" --arg message "$message" \
        --arg updatedAt "$(date -Iseconds 2> /dev/null || date)" \
        --arg logTail "$log_tail" \
        '{state:$state, message:$message, updatedAt:$updatedAt, logTail:$logTail}' > "$status_file"
}

kill_process_tree() {
    local pid="$1"
    local child

    [ -n "$pid" ] || return 0
    [ -d "/proc/$pid" ] || return 0

    if [ -r "/proc/$pid/task/$pid/children" ]; then
        for child in $(cat "/proc/$pid/task/$pid/children" 2> /dev/null); do
            kill_process_tree "$child"
        done
    fi

    kill "$pid" 2> /dev/null || true
}

run_with_timeout() {
    local limit="$1"
    local pid watchdog rc

    shift
    "$@" >> "$log_file" 2>&1 &
    pid="$!"

    (
        sleep "$limit"
        kill_process_tree "$pid"
    ) &
    watchdog="$!"

    wait "$pid"
    rc="$?"
    kill "$watchdog" 2> /dev/null || true
    wait "$watchdog" > /dev/null 2>&1 || true

    return "$rc"
}

write_status "running" "patch_update_running" ""

tmp="/tmp/podkop-subscriptions-install.sh"
cache_buster="$(date +%s 2> /dev/null || echo $$)"
install_url="https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/main/openwrt/install.sh?t=$cache_buster"
download_ok=0

if command -v curl > /dev/null 2>&1; then
    if run_with_timeout 45 curl -fsSL --connect-timeout 10 -m 30 -o "$tmp" "$install_url"; then
        download_ok=1
    else
        for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
            if run_with_timeout 45 curl -fsSL --connect-timeout 10 -m 30 \
                --resolve "raw.githubusercontent.com:443:$ip" \
                -o "$tmp" "$install_url"; then
                download_ok=1
                break
            fi
        done
    fi
else
    if run_with_timeout 45 wget -T 30 -O "$tmp" "$install_url"; then
        download_ok=1
    else
        for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
            if run_with_timeout 45 wget -T 30 --no-check-certificate --header="Host: raw.githubusercontent.com" \
                -O "$tmp" "https://$ip/moz9/podkop-patch-subscriptions/main/openwrt/install.sh?t=$cache_buster"; then
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

if run_with_timeout 240 env PODKOP_PATCH_VERSION="${PODKOP_PATCH_VERSION:-main}" sh "$tmp"; then
    if grep -q "PODKOP_PATCH_NOOP=1" "$log_file" 2> /dev/null; then
        write_status "success" "patch_update_noop" "$(tail -n 20 "$log_file" 2> /dev/null)"
    else
        write_status "success" "patch_update_success" "$(tail -n 20 "$log_file" 2> /dev/null)"
    fi
else
    write_status "error" "install_failed" "$(tail -n 20 "$log_file" 2> /dev/null)"
    exit 1
fi
EOF

    chmod +x "$runner"
    if command -v start-stop-daemon > /dev/null 2>&1; then
        start-stop-daemon -S -b -x "$runner" > /dev/null 2>&1
    elif command -v setsid > /dev/null 2>&1; then
        setsid "$runner" < /dev/null > /dev/null 2>&1 &
    else
        "$runner" < /dev/null > /dev/null 2>&1 &
    fi

    echo '{"success":true,"started":true}'
}
PATCH_UPDATE_EOF

	awk -v repl="$patch_update_function" '
	BEGIN {
		while ((getline line < repl) > 0) {
			replacement = replacement line "\n"
		}
		in_patch_update = 0
	}

	$0 == "subscription_patch_update() {" {
		printf "%s", replacement
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
		print "                    wget -T 30 -O \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print "        else"
		print "            if command -v curl > /dev/null 2>&1; then"
		print "                curl -fsSL --connect-timeout 10 -m 30 -o \"$filepath\" \"$url\" &&"
		print "                    [ -s \"$filepath\" ] && return 0"
		print "            else"
		print "                wget -T 30 -O \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
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

if [ -f "$helper_target" ] && { ! grep -q "raw.githubusercontent.com:443" "$helper_target" 2>/dev/null || grep -q "wget -T 30 -t" "$helper_target" 2>/dev/null; }; then
	awk '
	BEGIN { in_download = 0 }

	$0 == "download_to_file() {" {
		print "download_to_file() {"
		print "    local url=\"$1\""
		print "    local filepath=\"$2\""
		print "    local http_proxy_address=\"$3\""
		print "    local retries=\"${4:-3}\""
		print "    local wait=\"${5:-2}\""
		print "    local attempt raw_path ip"
		print ""
		print "    for attempt in $(seq 1 \"$retries\"); do"
		print "        rm -f \"$filepath\""
		print ""
		print "        if [ -n \"$http_proxy_address\" ]; then"
		print "            if command -v curl > /dev/null 2>&1; then"
		print "                curl -fsSL -x \"http://$http_proxy_address\" --connect-timeout 10 -m 30 -o \"$filepath\" \"$url\" &&"
		print "                    [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print "            if command -v wget > /dev/null 2>&1; then"
		print "                http_proxy=\"http://$http_proxy_address\" https_proxy=\"http://$http_proxy_address\" \\"
		print "                    wget -T 30 -O \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print "        else"
		print "            if command -v curl > /dev/null 2>&1; then"
		print "                curl -fsSL --connect-timeout 10 -m 30 -o \"$filepath\" \"$url\" &&"
		print "                    [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print "            if command -v wget > /dev/null 2>&1; then"
		print "                wget -T 30 -O \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
		print "            fi"
		print ""
		print "            case \"$url\" in"
		print "            https://raw.githubusercontent.com/*)"
		print "                raw_path=\"${url#https://raw.githubusercontent.com/}\""
		print "                raw_path=\"${raw_path%%\\?*}\""
		print "                if command -v wget > /dev/null 2>&1; then"
		print "                    for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do"
		print "                        wget -T 30 --no-check-certificate --header=\"Host: raw.githubusercontent.com\" \\"
		print "                            -O \"$filepath\" \"https://$ip/$raw_path\" && [ -s \"$filepath\" ] && return 0"
		print "                    done"
		print "                fi"
		print "                if command -v curl > /dev/null 2>&1; then"
		print "                    for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do"
		print "                        curl -fsSL --connect-timeout 10 -m 30 \\"
		print "                            --resolve \"raw.githubusercontent.com:443:$ip\" \\"
		print "                            -o \"$filepath\" \"$url\" && [ -s \"$filepath\" ] && return 0"
		print "                    done"
		print "                fi"
		print "                ;;"
		print "            esac"
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
if [ -f "$helper_target" ]; then
	chmod 644 "$helper_target"
fi

exit 0
