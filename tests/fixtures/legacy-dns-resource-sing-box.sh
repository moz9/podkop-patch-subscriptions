#!/bin/sh
case "${RESOURCE_CHECK_MODE:-normal}" in
  pressure) printf 'MemAvailable: 15000 kB\n' > "$PODKOP_DNS_BENCHMARK_MEMINFO_FILE";;
  hang) exec sleep 30;;
esac
exit 0
