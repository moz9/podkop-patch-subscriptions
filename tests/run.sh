#!/bin/sh
set -eu

test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

sh "$test_dir/test_update_manager_mode_env.sh"
sh "$test_dir/test_installer_v1_manager_bootstrap.sh"
sh "$test_dir/test_release_metadata_sync.sh"
