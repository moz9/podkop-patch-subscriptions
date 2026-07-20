#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
state_dir="$test_root/podkop-update-manager"
installer_path="$state_dir/installer.sh"
terminal_path="$test_root/installer.sh"
library="$test_root/installer-functions.sh"
result_file="$test_root/result"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$state_dir/lock"
sed \
    -e 's/\r$//' \
    -e "s|state_dir=\"/tmp/podkop-update-manager\"|state_dir=\"$state_dir\"|" \
    -e '/^tmp_dir="$(mktemp -d)"$/,$d' \
    "$repo_root/i" > "$library"

write_probe() {
    probe_path="$1"
    mkdir -p "$(dirname "$probe_path")"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'library="$1"'
        printf '%s\n' '. "$library"'
        printf '%s\n' 'if command -v update_manager_v1_requested_podkop_upgrade >/dev/null 2>&1 && update_manager_v1_requested_podkop_upgrade; then'
        printf '%s\n' '    printf true'
        printf '%s\n' 'else'
        printf '%s\n' '    printf false'
        printf '%s\n' 'fi'
    } > "$probe_path"
}

write_probe "$installer_path"
write_probe "$terminal_path"

run_probe() {
    label="$1"
    probe_path="$2"
    update_state="$3"
    force_state="$4"
    mode="$5"
    pid_state="$6"
    expected="$7"

    if [ "$pid_state" = matching ]; then
        printf '%s\n' "$$" > "$state_dir/lock/pid"
    else
        printf '%s\n' 999999 > "$state_dir/lock/pid"
    fi

    jq -cn \
        --arg updateMode "$mode" \
        '{updateMode:$updateMode,podkopUpdateAvailable:true,canUpdate:true}' \
        > "$state_dir/details.json"

    unset PODKOP_PATCH_UPDATE_PODKOP PODKOP_PATCH_FORCE_PODKOP_UPDATE
    if [ "$update_state" = one ]; then
        PODKOP_PATCH_UPDATE_PODKOP=1
        export PODKOP_PATCH_UPDATE_PODKOP
    fi
    case "$force_state" in
    zero)
        PODKOP_PATCH_FORCE_PODKOP_UPDATE=0
        export PODKOP_PATCH_FORCE_PODKOP_UPDATE
        ;;
    one)
        PODKOP_PATCH_FORCE_PODKOP_UPDATE=1
        export PODKOP_PATCH_FORCE_PODKOP_UPDATE
        ;;
    esac

    sh "$probe_path" "$library" > "$result_file"
    actual="$(cat "$result_file")"
    unset PODKOP_PATCH_UPDATE_PODKOP PODKOP_PATCH_FORCE_PODKOP_UPDATE

    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

run_probe 'v1 combined update worker' "$installer_path" one unset podkop_and_patch matching true
run_probe 'normal terminal installer' "$terminal_path" one unset podkop_and_patch matching false
run_probe 'explicit force opt-out' "$installer_path" one zero podkop_and_patch matching false
run_probe 'patch-only worker' "$installer_path" one unset patch matching false
run_probe 'stale worker state' "$installer_path" one unset podkop_and_patch stale false
run_probe 'implicit installer default' "$installer_path" unset unset podkop_and_patch matching false

printf '%s\n' 'PASS: v1 update-manager bootstrap requires verified combined-update provenance'
