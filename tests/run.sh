#!/bin/sh
set -eu

test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

sh "$test_dir/test_update_manager_mode_env.sh"
sh "$test_dir/test_patch_update_direction.sh"
sh "$test_dir/test_update_center_direction_ui.sh"
sh "$test_dir/test_installer_v1_manager_bootstrap.sh"
sh "$test_dir/test_fresh_podkop_install.sh"
sh "$test_dir/test_release_metadata_sync.sh"
sh "$test_dir/test_ui_regressions.sh"
sh "$test_dir/test_luci_versioned_assets.sh"
sh "$test_dir/test_installer_rollback_guard.sh"
sh "$test_dir/test_dns_primary_policy.sh"
sh "$test_dir/test_podkop_mutation_lock_coordination.sh"
sh "$test_dir/test_subscription_apply_backend_v2.sh"
sh "$test_dir/test_subscription_apply_contract.sh"
