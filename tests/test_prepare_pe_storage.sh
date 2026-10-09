#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$repo/scripts/prepare-pe-storage.sh" ] || { printf 'FAIL: storage preparation script missing\n' >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT INT TERM
sed -e 's/\r$//' -e '/^# ENTRYPOINT/,$d' "$repo/scripts/prepare-pe-storage.sh" > "$test_dir/library"
. "$test_dir/library"
source_root="$test_dir/root"
backup_root="$test_dir/storage/private"
mkdir -p "$source_root" "$backup_root/offloaded"
external_mount="$test_dir/storage"
external_device=/dev/test
mount_table="$test_dir/mounts"
printf '/dev/test %s ext4 rw,noatime 0 0\n' "$external_mount" > "$mount_table"
storage_idle_path() { return 0; }
# Keep fixture durability checks isolated from the host's unrelated disks.
sync() { :; }
# Real target BusyBox sort has no -o support.
sort() {
    for argument in "$@"; do [ "$argument" != -o ] || return 2; done
    command sort "$@"
}
name=podkop-agh-backup-20260619-142812.tar.gz
printf 'original backup\n' > "$source_root/$name"
if storage_candidate "$source_root/not-a-backup"; then exit 1; fi
if storage_candidate "$source_root/../etc/config/zerotier"; then exit 1; fi
storage_candidate "$source_root/$name"
ln -s "$source_root/$name" "$source_root/podkop-selection-test.symlink"
if storage_candidate "$source_root/podkop-selection-test.symlink"; then exit 1; fi
storage_offload "$source_root/$name"
[ ! -e "$source_root/$name" ]
printf 'original backup\n' > "$test_dir/expected"
cmp "$test_dir/expected" "$backup_root/offloaded/$name"
# Never overwrite an older archived copy; preserve both source and destination.
printf 'different backup\n' > "$source_root/$name"
if (storage_offload "$source_root/$name") > "$test_dir/collision" 2>&1; then exit 1; fi
grep -q 'уже существует' "$test_dir/collision"
grep -q 'different backup' "$source_root/$name"
# Exercise a real directory, including hidden files and a symlink.
name=podkop-patch-subscriptions-backup-20260101-010203-AbCd12
mkdir -p "$source_root/$name/patch-rollback"
printf 'secret config\n' > "$source_root/$name/patch-rollback/.config"
ln -s .config "$source_root/$name/patch-rollback/link"
storage_offload "$source_root/$name"
[ ! -d "$source_root/$name" ]
[ -L "$backup_root/offloaded/$name/patch-rollback/link" ]
grep -q 'secret config' "$backup_root/offloaded/$name/patch-rollback/.config"
# A failed verification may leave an external copy, but must keep the source.
name=podkop-selection-test.Bad123
mkdir "$source_root/$name"
printf 'keep me\n' > "$source_root/$name/file"
if (cp() { command cp "$@"; printf 'corrupted copy\n' > "$backup_root/offloaded/$name/file"; }; storage_offload "$source_root/$name") > "$test_dir/verify-error" 2>&1; then exit 1; fi
[ -f "$source_root/$name/file" ]
grep -q 'проверка копии' "$test_dir/verify-error"
# A disk disappearing during copy must never lead to deleting the source.
name=podkop-selection-test.DiskGone
mkdir "$source_root/$name"
printf 'keep after unmount\n' > "$source_root/$name/file"
if (cp() { command cp "$@"; printf '' > "$mount_table"; }; storage_offload "$source_root/$name") > "$test_dir/mount-error" 2>&1; then
    printf 'FAIL: source removed after external mount disappeared\n' >&2; exit 1
fi
[ -f "$source_root/$name/file" ]
printf '/dev/test %s ext4 rw,noatime 0 0\n' "$external_mount" > "$mount_table"
# A newly active backup must be kept even when its copy was verified.
name=podkop-selection-test.BecameBusy
mkdir "$source_root/$name"
printf 'now in use\n' > "$source_root/$name/file"
if (storage_idle_path() { return 1; }; storage_offload "$source_root/$name") > "$test_dir/busy-error" 2>&1; then exit 1; fi
[ -f "$source_root/$name/file" ]
# A failed durability flush must retain the verified source too.
name=podkop-selection-test.FlushFailed
printf 'keep after flush failure\n' > "$source_root/$name"
if (sync() { return 1; }; storage_offload "$source_root/$name") > "$test_dir/flush-error" 2>&1; then exit 1; fi
[ -f "$source_root/$name" ]
grep -q 'не удалось записать копию' "$test_dir/flush-error"
# Commit the destination to disk before removing the verified original.
name=podkop-selection-test.FlushFirst
printf 'flush first\n' > "$source_root/$name"
(
    sync() { printf 'sync\n' >> "$test_dir/order"; }
    rm() { [ "$(tail -n 1 "$test_dir/order")" = sync ]; command rm "$@"; }
    storage_offload "$source_root/$name"
)
[ ! -e "$source_root/$name" ]
sh "$repo/scripts/prepare-pe-storage.sh" --help > "$test_dir/help"
grep -q -- '--check' "$test_dir/help"
grep -q -- '--apply' "$test_dir/help"
if sh "$repo/scripts/prepare-pe-storage.sh" --invalid > "$test_dir/invalid" 2>&1; then exit 1; fi
printf 'PASS: allowlist, symlink refusal, verified move, no overwrite, retained failed source\n'
