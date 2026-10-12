// Reconstruct four known historical section-patch contexts in a private fixture.
// CAS changed these after the section patch was published. Normalize only those
// contexts before reversing the immutable patch. The real updater subsequently
// handles the current source-upgraded fixture. Unknown drift fails closed.
import fs from 'node:fs';
const path = process.argv[2];
let text = fs.readFileSync(path, 'utf8');
function replaceInFunction(name, oldText, newText) {
    const start = text.indexOf(name + '() {\n');
    const end = text.indexOf('\n}\n', start) + 3;
    const body = text.slice(start, end);
    if (start < 0 || end < 3 || body.split(oldText).length !== 2)
        throw new Error('Unknown historical fixture context: ' + name);
    text = text.slice(0, start) + body.replace(oldText, () => newText) + text.slice(end);
}

replaceInFunction('subscription_apply_v2_reload', `    # Reload has legacy UCI/ubus consumers outside our private context. Never
    # activate someone else's unsaved LuCI form edits. Reads remain available.
    if ! subscription_cas_shared_clean; then
        PODKOP_SECTION_ERROR=uci_pending_changes
        PODKOP_SECTION_APPLY_RUNTIME_UNCHANGED=1
        return 1
    fi
`, ``);

replaceInFunction('subscription_apply_v2_restore', `    cp -p "$PODKOP_CONFIG" "$SUBSCRIPTION_CAS_DIR/config/$SUBSCRIPTION_CAS_PACKAGE" || restore_ok=0
    subscription_cas_config_load
`, `    config_load "$PODKOP_CONFIG"
`);

replaceInFunction('set_subscription_sections_enabled', `    if command -v podkop_section_enabled >/dev/null && podkop_section_enabled; then
        if ! podkop_section_preflight "$payload"; then
            subscription_apply_v2_fail validation "\${PODKOP_SECTION_ERROR:-section_isolation_unavailable}" false
            return $?
        fi
    fi
`, ``);

replaceInFunction('set_subscription_sections_enabled', `    trap 'subscription_apply_v2_interrupted' INT TERM HUP


    payload_file=`, `    trap 'subscription_apply_v2_interrupted' INT TERM HUP

    if command -v podkop_section_enabled >/dev/null && podkop_section_enabled; then
        if ! podkop_section_preflight "$payload"; then
            subscription_apply_v2_fail validation "\${PODKOP_SECTION_ERROR:-section_isolation_unavailable}" false
            return $?
        fi
    fi

    payload_file=`);

replaceInFunction('subscription_services_context', `    settings="$(if command -v subscription_cas_settings >/dev/null; then subscription_cas_settings; else uci -q show podkop.settings; fi)" || return 1
`, `    settings="$(uci -q show podkop.settings)" || return 1
`);

fs.writeFileSync(path, text);
