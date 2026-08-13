#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_function() {
    script="$1"
    function_name="$2"
    awk -v wanted="$function_name" '
        $0 ~ "^" wanted "\\(\\) \\{" { printing = 1 }
        printing {
            print
            line = $0
            opens += gsub(/\{/, "{", line)
            closes += gsub(/\}/, "}", line)
            if (opens > 0 && opens == closes) exit
        }
    ' "$script"
}

assert_mutation_scope() {
    script="$1"
    operation="$2"
    next_function="$3"

    sed -n "/^${operation}() {/,/^${next_function}() {/p" "$script" |
        grep -q 'podkop_mutation_lock_acquire' ||
        fail "$operation in $script must acquire the shared Podkop mutation lock"
}

exercise_lock_protocol() {
    script="$1"
    test_root="$2"
    fixture="$test_root/$(basename "$script").fixture.sh"
    lock_dir="$test_root/$(basename "$script").lock.d"
    legacy_lock="$test_root/$(basename "$script").legacy.lock"
    ready="$test_root/$(basename "$script").ready"
    stop="$test_root/$(basename "$script").stop"
    legacy_ready="$test_root/$(basename "$script").legacy.ready"
    legacy_stop="$test_root/$(basename "$script").legacy.stop"

    {
        printf 'PODKOP_MUTATION_LOCK_DIR=%s\n' "'$lock_dir'"
        printf 'PODKOP_MUTATION_LEGACY_LOCK_FILE=%s\n' "'$legacy_lock'"
        printf 'PODKOP_MUTATION_LOCK_HELD=0\n'
        extract_function "$script" podkop_mutation_lock_pid_alive
        extract_function "$script" podkop_mutation_legacy_lock_busy
        extract_function "$script" podkop_mutation_lock_acquire
        extract_function "$script" podkop_mutation_lock_release
        cat <<'EOF'
case "$1" in
    hold)
        podkop_mutation_lock_acquire test_holder || exit 10
        trap 'podkop_mutation_lock_release' EXIT INT TERM
        : > "$2"
        while [ ! -e "$3" ]; do sleep 1; done
        ;;
    try)
        if podkop_mutation_lock_acquire test_contender; then
            podkop_mutation_lock_release
            exit 11
        fi
        ;;
    release_foreign)
        podkop_mutation_lock_release
        ;;
    acquire_stale)
        podkop_mutation_lock_acquire test_stale || exit 12
        awk -v pid="$$" 'NR == 1 && $1 == pid { found = 1 } END { exit !found }' "$PODKOP_MUTATION_LOCK_DIR/owner" || exit 13
        podkop_mutation_lock_release
        ;;
esac
EOF
    } > "$fixture"

    sh "$fixture" hold "$ready" "$stop" &
    holder_pid=$!
    attempts=0
    while [ ! -e "$ready" ] && [ "$attempts" -lt 20 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    [ -e "$ready" ] || fail "$script did not acquire the mutation lock"
    awk -v pid="$holder_pid" 'NR == 1 && $1 == pid { found = 1 } END { exit !found }' "$lock_dir/owner" ||
        fail "$script did not record the owner PID"
    awk -v pid="$holder_pid" 'NR == 1 && $1 == pid { found = 1 } END { exit !found }' "$legacy_lock" ||
        fail "$script did not bridge the lock to the legacy lock file"

    sh "$fixture" try || fail "$script allowed a concurrent mutation"
    sh "$fixture" release_foreign || fail "$script foreign release command failed"
    [ -d "$lock_dir" ] || fail "$script released a lock owned by another process"
    [ -s "$legacy_lock" ] || fail "$script released a legacy lock owned by another process"

    : > "$stop"
    wait "$holder_pid"
    holder_pid=""
    [ ! -d "$lock_dir" ] || fail "$script did not release its owned lock"
    [ ! -e "$legacy_lock" ] || fail "$script did not release its owned legacy lock"

    sh -c '
        printf "%s legacy_holder 0\n" "$$" > "$1"
        : > "$2"
        while [ ! -e "$3" ]; do sleep 1; done
    ' sh "$legacy_lock" "$legacy_ready" "$legacy_stop" &
    legacy_holder_pid=$!
    attempts=0
    while [ ! -e "$legacy_ready" ] && [ "$attempts" -lt 20 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    [ -e "$legacy_ready" ] || fail "$script legacy holder did not start"
    sh "$fixture" try || fail "$script ignored a live legacy lock"
    [ ! -d "$lock_dir" ] || fail "$script left the directory lock after a legacy-lock conflict"
    [ -s "$legacy_lock" ] || fail "$script removed a live legacy lock owned by another process"
    : > "$legacy_stop"
    wait "$legacy_holder_pid"
    legacy_holder_pid=""
    rm -f "$legacy_lock"

    : > "$legacy_lock"
    sh "$fixture" try || fail "$script acquired during an ownerless legacy-lock creation window"
    [ -e "$legacy_lock" ] || fail "$script removed an ownerless live legacy lock"
    rm -f "$legacy_lock"

    mkdir "$lock_dir"
    sh "$fixture" try || fail "$script acquired during an ownerless directory-lock creation window"
    [ -d "$lock_dir" ] || fail "$script removed an ownerless live directory lock"
    rmdir "$lock_dir"

    mkdir "$lock_dir"
    printf '999999 stale 0\n' > "$lock_dir/owner"
    printf '999999 stale 0\n' > "$legacy_lock"
    sh "$fixture" acquire_stale || fail "$script did not recover a stale lock"
    [ ! -d "$lock_dir" ] || fail "$script left the recovered lock behind"
    [ ! -e "$legacy_lock" ] || fail "$script left the recovered legacy lock behind"
}

optimizer="openwrt/podkop-dns-optimizer"
failover="openwrt/podkop-dns-failover"

for script in "$optimizer" "$failover"; do
    grep -q '/tmp/podkop-subscription-action.lock.d' "$script" ||
        fail "$script must use the subscription action lock directory"
    grep -q 'PODKOP_MUTATION_LEGACY_LOCK_FILE=.*\/tmp\/podkop-subscription-action.lock}' "$script" ||
        fail "$script must bridge rolling upgrades through the legacy lock file"
    grep -q "printf '%s %s %s\\\\n'.*owner" "$script" ||
        fail "$script must write an owner PID and action"
done

assert_mutation_scope "$optimizer" run_apply run_rollback
assert_mutation_scope "$optimizer" run_rollback pid_alive
assert_mutation_scope "$failover" switch_to_slot run_probe_command

grep -q 'podkop_action_busy' "$optimizer" ||
    fail 'DNS optimizer must expose a clear busy status'
grep -q 'podkop_action_busy' "$failover" ||
    fail 'DNS failover must expose a clear busy status/error'

test_root="$(mktemp -d)"
holder_pid=""
legacy_holder_pid=""
cleanup() {
    [ -z "$holder_pid" ] || kill "$holder_pid" 2> /dev/null || true
    [ -z "$legacy_holder_pid" ] || kill "$legacy_holder_pid" 2> /dev/null || true
    rm -rf "$test_root"
}
trap 'cleanup' EXIT INT TERM
exercise_lock_protocol "$optimizer" "$test_root"
exercise_lock_protocol "$failover" "$test_root"

printf '%s\n' 'PASS: Podkop DNS mutations share an owner-aware action lock'
