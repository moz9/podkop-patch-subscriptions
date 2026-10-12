#!/bin/sh
set -eu
umask 077
mode=$1
mkdir -p "$HOME"
python3 /ci/self-test.py
if [ "$mode" = self-test ]; then exit 0; fi

status=0
case "$mode" in
all|tests)
    printf '%s\n' 'CI coverage: real-UCI CAS is NOT provisioned; its SKIP is expected and is not a six-runtime validation claim.'
    sh tests/run.sh > /tmp/candidate-tests.log 2>&1 || status=$?
    cat /tmp/candidate-tests.log
    if grep -Fq 'SKIP real UCI CAS:' /tmp/candidate-tests.log; then
        printf '%s\n' '::warning::Real-UCI CAS skipped. Hosted CI does not validate the six-runtime real-UCI matrix.'
    else
        printf '%s\n' '::error::Expected explicit real-UCI CAS SKIP was not observed; CI coverage must be reviewed.'
        [ "$status" -ne 0 ] || status=1
    fi
    ;;
esac

case "$mode" in
all|lint)
    printf '%s\n' 'Running shellcheck error-severity gate (failures are not suppressed).'
    set -- a i s openwrt/install.sh openwrt/*.sh \
        openwrt/podkop-dns-failover openwrt/podkop-dns-failover.init \
        openwrt/podkop-dns-optimizer openwrt/podkop-update-manager \
        openwrt/runtime-0.7.20/usr/bin/podkop openwrt/runtime-0.7.22/usr/bin/podkop
    if [ "$(jq -r '.channel // "legacy"' openwrt/update-manifest.json)" = podkop-pe ]; then
        set -- "$@" m scripts/prepare-pe-storage.sh openwrt/podkop-dns-benchmark \
            openwrt/runtime-0.7.23/usr/bin/podkop openwrt/runtime-0.7.23/usr/lib/podkop/*.sh \
            openwrt/runtime-0.7.24/usr/bin/podkop openwrt/runtime-0.7.24/usr/lib/podkop/*.sh \
            openwrt/podkop-section-runtime openwrt/podkop-section-worker.init
    fi
    shellcheck -s sh -S error "$@" || status=1
    shellcheck -s sh -S error /ci/run-inside.sh /ci/guard-bin/* /src/scripts/verify-candidate-ci.sh || status=1
    ;;
esac

if [ -s /tmp/ci-guard.log ]; then
    cat /tmp/ci-guard.log
    printf '%s\n' '::error::A non-fixture system/router action was attempted.'
    status=125
fi
printf 'OFFLINE CANDIDATE CI EXIT: %s\n' "$status"
exit "$status"
