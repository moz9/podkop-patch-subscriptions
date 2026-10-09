#!/bin/sh
set -eu
case "${0##*/}:$1" in
    sing-box:check) exit 0;;
    sing-box:run) printf '%s\n' "$$" > "$PODKOP_SERVICE_PROCESS_FIXTURE/probe.pid"; touch "$PODKOP_SERVICE_PROCESS_FIXTURE/started"; exec sleep 30;;
    curl:*) printf '%s\n' "$$" > "$PODKOP_SERVICE_PROCESS_FIXTURE/curl.pid"; touch "$PODKOP_SERVICE_PROCESS_FIXTURE/curl-started"; exec sleep 30;;
    *) exit 2;;
esac
