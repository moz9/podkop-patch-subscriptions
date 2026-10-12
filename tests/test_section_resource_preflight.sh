#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$work/bin" "$work/state"
cat > "$work/bin/awk" <<'SH'
#!/bin/sh
case "$*" in *MemAvailable*) printf '%s\n' "$SECTION_TEST_AVAILABLE";; *) exec /usr/bin/awk "$@";; esac
SH
chmod 700 "$work/bin/awk"
PATH="$work/bin:$PATH"; export PATH
PODKOP_SECTION_ROOT="$work/state"; export PODKOP_SECTION_ROOT
printf '%s\n' '{"version":2,"sections":[{"section":"main"},{"section":"GEOBLOCK"}]}' > "$work/state/metadata.json"
printf '{}\n' > "$work/state/logical.json"
before="$(sha256sum "$work/state/"*)"
SECTION_TEST_AVAILABLE=27528; export SECTION_TEST_AVAILABLE
if sh "$repo/openwrt/podkop-section-runtime" preflight > "$work/result" 2>&1; then fail 'low-memory preflight succeeded'; fi
grep -Fxq 'section_runtime: memory_floor' "$work/result" || fail 'preflight did not expose exact memory floor'
[ "$before" = "$(sha256sum "$work/state/"*)" ] || fail 'resource preflight changed runtime files'
[ "$(find "$work/state" -mindepth 1 | wc -l)" -eq 2 ] || fail 'preflight created runtime state'
SECTION_TEST_AVAILABLE=invalid
if sh "$repo/openwrt/podkop-section-runtime" preflight > "$work/result" 2>&1; then fail 'unknown memory accepted'; fi
grep -Fxq 'section_runtime: memory_unavailable' "$work/result" || fail 'unavailable memory not distinguished'
SECTION_TEST_AVAILABLE=40000
if grep -q '^resource_count_floor()' "$repo/openwrt/podkop-section-runtime"; then
  if sh "$repo/openwrt/podkop-section-runtime" preflight > "$work/result" 2>&1; then fail 'PE worker-count floor bypassed'; fi
  grep -Fxq 'section_runtime: worker_count_memory_floor' "$work/result" || fail 'PE count floor not reported'
else
  sh "$repo/openwrt/podkop-section-runtime" preflight || fail 'legacy floor changed'
fi
SECTION_TEST_AVAILABLE=65536
sh "$repo/openwrt/podkop-section-runtime" preflight || fail 'sufficient memory rejected'
. "$repo/openwrt/podkop-section-hooks.sh"
podkop_section_name() { printf main; }
podkop_section_enabled() { return 0; }
podkop_section_names() { printf '["main"]'; }
podkop_section_ready() { return 0; }
uci() { [ "$*" = '-q changes podkop' ] || { touch "$work/unexpected-uci-write"; return 1; }; }
podkop_section_manager() { printf '%s\n' "$manager_error" >&2; return 1; }
for reason in memory_floor worker_count_memory_floor memory_unavailable unknown_private_detail; do
  manager_error="section_runtime: $reason"
  if podkop_section_preflight '{"sections":[{"section":"main"}]}' > "$work/output" 2>&1; then fail "hook accepted $reason"; fi
  case "$reason" in memory_floor|worker_count_memory_floor) expected=section_memory_low;; memory_unavailable) expected=section_memory_unavailable;; *) expected=section_runtime_failed;; esac
  [ "$PODKOP_SECTION_ERROR" = "$expected" ] || fail "unsafe or missing mapping for $reason"
  [ ! -s "$work/output" ] || fail 'hook leaked manager output'
  [ ! -e "$work/unexpected-uci-write" ] || fail 'preflight mutated UCI'
done
podkop_section_candidate() { printf '{}\n' > "$1"; }
manager_error='section_runtime: memory_floor'
if podkop_section_apply > "$work/output" 2>&1; then fail 'failed manager apply accepted'; fi
[ "$PODKOP_SECTION_ERROR" = section_memory_low ] || fail 'apply discarded manager reason'
[ "$PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED" = 1 ] || fail 'preactivation memory rejection not recorded'
[ ! -s "$work/output" ] || fail 'apply leaked manager output'
manager_error='section_runtime: unknown_private_detail'
if podkop_section_apply > "$work/output" 2>&1; then fail 'unknown manager failure accepted'; fi
[ "$PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED" = 0 ] || fail 'unknown manager failure falsely proved unchanged runtime'
manager_error="$(printf '%s\n' 'section_runtime: memory_floor' 'section_runtime: worker_apply_failed')"
if podkop_section_apply > "$work/output" 2>&1; then fail 'postactivation failure accepted'; fi
[ "$PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED" = 0 ] || fail 'late memory failure falsely proved unchanged runtime'
[ "$PODKOP_SECTION_ERROR" = section_runtime_failed ] || fail 'compound failure was reduced to a preactivation memory error'
podkop_section_candidate() { return 1; }
if podkop_section_apply; then fail 'candidate failure accepted'; fi
[ "$PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED" = 1 ] || fail 'candidate failure falsely requires runtime rollback'
echo 'PASS: resource preflight refuses before mutation and safely preserves memory errors'

