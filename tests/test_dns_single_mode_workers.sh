#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PODKOP_DNS_BENCHMARK_LIBRARY_ONLY=1 PODKOP_DNS_OPTIMIZER_LIBRARY_ONLY=1
export PODKOP_DNS_BENCHMARK_OPTIMIZER="$repo/openwrt/podkop-dns-optimizer"
export PODKOP_DNS_BENCHMARK_STATE_DIR="$tmp/state" PODKOP_DNS_BENCHMARK_PERSIST_DIR="$tmp/persist"
export PODKOP_SECTION_ROOT="$tmp/native" PODKOP_DNS_BENCHMARK_WORKERS_DIR="$tmp/native/workers"
. "$repo/openwrt/podkop-dns-benchmark"
mkdir -p "$DB_DIR" "$DB_PERSIST" "$DB_WORKERS_DIR/main"
printf '{"outbounds":[],"route":{}}\n' > "$tmp/front.json"
printf '{"dormant":true}\n' > "$DB_WORKERS_DIR/main/worker.json"
printf '{"dormant":true}\n' > "$PODKOP_SECTION_ROOT/worker.json"
printf 'single\n' > "$PODKOP_SECTION_ROOT/runtime-mode"
command -v db_worker_configs >/dev/null 2>&1 || fail 'mode-aware benchmark worker enumerator missing'
[ -z "$(db_worker_configs)" ] || fail 'single mode enumerates dormant split workers'
uci() { case "$*" in 'export podkop') printf 'stable-config\n';; '-q get podkop.settings.config_path') printf '%s/front.json\n' "$tmp";; *) :;; esac; }
db_engine_identity() { printf 'stable-engine\n'; }
before="$(db_fingerprint)"
printf '{"dormant":"changed-without-runtime-impact"}\n' > "$DB_WORKERS_DIR/main/worker.json"
after="$(db_fingerprint)"
[ "$before" = "$after" ] || fail 'dormant worker invalidates single runtime fingerprint'
if command -v db_child_admission >/dev/null 2>&1; then
    db_production_capture() { :; }
    db_wait_admission() { printf '%s\n' "$1" > "$tmp/required"; }
    db_child_admission pair || fail 'single mode admission rejected'
    [ "$(cat "$tmp/required")" = 32768 ] || fail 'dormant worker charged in RAM admission'
else
    # PE keeps its conservative measured full-clone floor; stale workers must
    # not add24MiB each to the endpoint-only decision.
    printf 'MemAvailable: 150000 kB\n' > "$tmp/meminfo"
    export PODKOP_DNS_BENCHMARK_MEMINFO_FILE="$tmp/meminfo"
    db_benchmark() { fail 'dormant worker forced endpoint-only fallback'; }
    if db_endpoint_only_if_needed; then fail '150000KiB deferred despite single-mode147456KiB envelope'; fi
fi
rm "$PODKOP_SECTION_ROOT/runtime-mode"
[ -n "$(db_worker_configs)" ] || fail 'legacy split mode workers disappeared'
echo 'PASS: single-mode benchmark ignores preserved split files in fingerprint, graph and RAM accounting'
