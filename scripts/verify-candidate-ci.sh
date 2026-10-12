#!/bin/sh
# Run candidate checks in a disposable, offline Linux sandbox. No fallback.
set -eu
umask 077

tooling=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=${1:-"$(dirname "$tooling")"}
repo=$(CDPATH= cd -- "$repo" && pwd)
mode=${2:-all}
case "$mode" in all|tests|lint|self-test) ;; *) echo 'Usage: verify-candidate-ci.sh [repository] [all|tests|lint|self-test]' >&2; exit 2;; esac
[ -f "$repo/tests/run.sh" ] && [ -f "$repo/openwrt/update-manifest.json" ] || { echo 'Missing root-layout candidate' >&2; exit 2; }
for program in unshare bwrap python3 node jq timeout; do
    command -v "$program" >/dev/null 2>&1 || { echo "Missing prerequisite: $program" >&2; exit 2; }
done
case "$mode" in all|lint) command -v shellcheck >/dev/null 2>&1 || { echo 'Missing prerequisite: shellcheck' >&2; exit 2; };; esac

node_path=$(command -v node)
node_dir=$(CDPATH= cd -- "$(dirname -- "$node_path")" && pwd)
parent_netns=$(readlink /proc/self/ns/net)
bwrap=$(command -v bwrap)
unshare=$(command -v unshare)
python=$(command -v python3)

# Expose only system tools/libraries, candidate sources and this checked-in CI
# harness. Host homes, /run, workspace siblings and runner credentials are absent.
set -- "$bwrap" --die-with-parent --new-session --unshare-pid --unshare-ipc --unshare-uts \
    --hostname podkop-candidate-ci --cap-drop ALL --clearenv \
    --ro-bind /usr /usr --dir /etc --dir /src --dir /ci \
    --ro-bind "$repo" /src --ro-bind "$tooling/ci" /ci \
    --ro-bind "$node_dir" /node-bin
for directory in /bin /sbin /lib /lib64; do
    if [ -L "$directory" ]; then
        set -- "$@" --symlink "$(readlink "$directory")" "$directory"
    elif [ -d "$directory" ]; then
        set -- "$@" --ro-bind "$directory" "$directory"
    fi
done
for file in /etc/ld.so.cache /etc/nsswitch.conf /etc/passwd /etc/group /etc/hosts; do
    [ ! -f "$file" ] || set -- "$@" --ro-bind "$file" "$file"
done
[ ! -d /etc/alternatives ] || set -- "$@" --ro-bind /etc/alternatives /etc/alternatives
if [ -d "$repo/.git" ]; then
    set -- "$@" --tmpfs /src/.git --remount-ro /src/.git
elif [ -f "$repo/.git" ]; then
    set -- "$@" --ro-bind /dev/null /src/.git
fi
set -- "$@" --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
    --remount-ro / --chdir /src \
    --setenv PATH /ci/guard-bin:/node-bin:/usr/bin:/bin \
    --setenv HOME /tmp/ci-home --setenv TMPDIR /tmp --setenv LC_ALL C --setenv TZ UTC \
    -- /bin/sh /ci/run-inside.sh "$mode"

# Clear the environment BEFORE namespace setup as well as at the sandbox
# boundary. Namespace failure is fatal; never retry without isolation.
exec env -i PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
    timeout --signal=TERM --kill-after=15s 12m \
    "$unshare" --user --map-root-user --net --fork --kill-child \
    "$python" "$tooling/ci/netns-loopback.py" "$parent_netns" "$@"
