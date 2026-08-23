#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
library="$test_root/installer-functions.sh"

cleanup() {
	rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

fail_test() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

sed \
	-e 's/\r$//' \
	-e '/^tmp_dir="$(mktemp -d)"$/,$d' \
	"$repo_root/i" > "$library"

# shellcheck disable=SC1090
. "$library"

command -v run_podkop_reload_with_retry >/dev/null 2>&1 ||
	fail_test 'the unified installer does not retry the first transient Podkop start failure'

attempts=0
run_podkop_reload() {
	attempts=$((attempts + 1))
	[ "$attempts" -ge 2 ]
}
PODKOP_PATCH_RELOAD_RETRY_DELAY=0
export PODKOP_PATCH_RELOAD_RETRY_DELAY

run_podkop_reload_with_retry 'test command' ||
	fail_test 'the unified installer rejected a patch after the second Podkop start succeeded'
[ "$attempts" -eq 2 ] ||
	fail_test "the unified installer made $attempts start attempts instead of 2"

attempts=0
run_podkop_reload() {
	attempts=$((attempts + 1))
	return 1
}
if run_podkop_reload_with_retry 'test command'; then
	fail_test 'the unified installer accepted two failed Podkop starts'
fi
[ "$attempts" -eq 2 ] ||
	fail_test "the unified installer made $attempts failed attempts instead of 2"

grep -q 'run_podkop_reload_with_retry "\$reload_command"' "$repo_root/i" ||
	fail_test 'the installation path does not use the first-run retry'

printf '%s\n' 'PASS: unified installer retries a transient first Podkop start failure'
