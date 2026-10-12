#!/bin/sh
set -eu
test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
for suite in \
    subscription_backend_current \
    dns_quick_budget \
    update_manager_mode_env patch_update_direction update_center_repair \
    installer_v1_manager_bootstrap installer_first_run_retry installer_rollback_guard \
    single_runtime single_runtime_integration section_worker_gc \
    subscription_light_probe subscription_probe_resources_worker dns_single_mode_workers dns_native_benchmark \
    pe_0724_boundary pe_0724_runtime pe_0724_sections pe_0724_section_runtime \
    pe_installer pe_deferred_activation pe_runtime pe_optional_selection_backend \
    pe_dns_engine_identity pe_dns_benchmark pe_dns_pairs pe_dns_recommend \
    pe_dns_two_stage pe_dns_verified pe_dns_reserve pe_dns_status_race \
    pe_dns_bootstrap_safety pe_dns_failover_safety pe_dns_failover_signals \
    pe_dns_parallel pe_dns_resource_safety pe_dns_oom_priority pe_dns_cancel_identity \
    pe_dns_apply pe_dns_delivery pe_dns_protocols dns_catalog_delivery dns_diagnostic_bounded \
    release_metadata_sync subscription_apply_backend_v2 subscription_apply_contract \
    subscription_seamless_refresh subscription_deferred subscription_hwid_placeholder_guard \
    subscription_sources subscription_sources_delivery subscription_isolated_probe subscription_probe_context \
    subscription_services subscription_gemini_v2 subscription_services_cancel \
    subscription_services_delivery subscription_service_snapshot safe_restart_continuity source_ruleset_reuse subscription_source_actions \
    subscription_choice_identity subscription_operation_state subscription_game_filter \
    subscription_selection_backend section_traffic_context section_candidate_boundary subscription_empty_admission_error; do
    printf 'RUN: %s\n' "$suite"
    sh "$test_dir/test_$suite.sh"
done
for suite in \
    update_entrypoints_ui \
    dns_quick_ui \
    pe_0724_settings pe_dns_catalog pe_dns_benchmark_ui pe_ui pe_section_layout \
    pe_grid_modal_save dashboard_display_filters subscription_read_recovery \
    settings_layout_ui diagnostic_truth mark_classification subscription_services_ui \
    subscription_admission_ui service_filter_delivery subscription_sources_ui \
    subscription_source_actions_ui subscription_pending_ui subscription_selection_ui \
    subscription_tag_picker subscription_picker_retention subscription_game_filter subscription_optional_selection_ui \
    subscription_timeout_reconciliation subscription_section_apply_ui pe_stable_layout; do
    printf 'RUN: %s\n' "$suite"
    node "$test_dir/test_$suite.mjs"
done
printf '%s\n' 'PASS: preparation suite (no package migration or live activation)'
