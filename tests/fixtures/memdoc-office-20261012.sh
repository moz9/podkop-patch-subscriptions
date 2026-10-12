#!/bin/sh

XRAY="/etc/init.d/xray"
SINGBOX="/etc/init.d/sing-box"
BRIDGER="/etc/init.d/bridger"

[ -e "$XRAY" ] && USE_XRAY=1 || USE_XRAY=0
[ -e "$SINGBOX" ] && USE_SINGBOX=1 || USE_SINGBOX=0
[ -e "$BRIDGER" ] && USE_BRIDGER=1 || USE_BRIDGER=0

if [ "$USE_XRAY" -eq 0 ] && [ "$USE_SINGBOX" -eq 0 ] && [ "$USE_BRIDGER" -eq 0 ]; then
	exit 0
fi

TOTAL_MEM=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

if [ "$TOTAL_MEM" -gt 230000 ]; then
	THRESHOLD=20000
elif [ "$TOTAL_MEM" -gt 100000 ]; then
	THRESHOLD=3000
else
	exit 0
fi

restart_service_if_running() {
	SERVICE=$1
	if [ -e "$SERVICE" ] && $SERVICE status | grep -q "running"; then
		$SERVICE restart
	fi
}

while true; do
	FREE_MEM=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

	if [ "$FREE_MEM" -le "$THRESHOLD" ]; then
		[ "$USE_XRAY" -eq 1 ] && restart_service_if_running "$XRAY"
		[ "$USE_SINGBOX" -eq 1 ] && restart_service_if_running "$SINGBOX"
		[ "$USE_BRIDGER" -eq 1 ] && restart_service_if_running "$BRIDGER"
		sleep 10
	fi

	sleep 1
done
