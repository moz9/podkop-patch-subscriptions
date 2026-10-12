# Coherent subscription snapshots and stale-tab protection

The subscription UI reads `get_subscription_snapshot`, a version-1 object with saved section policy, source/item/service display data, and a semantic `revision` per section. It holds the existing shared action lock while reading local state. It never refreshes subscriptions, probes services, downloads data, writes generation counters, or activates a configuration during a read. An uninitialized section is returned with empty items; malformed existing data fails closed.

Every row passed to `set_subscription_sections_enabled` must contain `expectedRevision`. Missing tokens return `revision_required`; malformed tokens return `invalid_revision`; changed/deleted bases return `revision_conflict`. Responses include `success:false,committed:false,reloaded:false`. All requested sections are checked before any staging, and checked again after validation. One stale row rejects the whole request. Another section's committed edits do not invalidate a section's token. Legacy clients cannot obtain a fresh token implicitly or bypass the contract through single/bulk wrappers.

CLI forms:

- `get_subscription_snapshot`
- `set_subscription_link_enabled SECTION ID ENABLED REVISION`
- `set_subscription_links_enabled SECTION REVISION ID ENABLED [ID ENABLED ...]`
- `set_subscription_sections_enabled JSON`, with `sections[].expectedRevision`

## What the token means

SHA-256 covers canonical target-section configuration, normalized set-valued choices/tags/services, stable node identity and provenance, ordered source/connection content, saved admission proof with its timestamps/context, and global DNS/service settings. Set ordering and duplicate choices do not matter; routing-order arrays do. Duplicate node IDs fail closed. Stored evidence changes invalidate the token; clock progression itself does not. Admission still independently rejects expired proof.

Tokens describe content, not history. Deleting and recreating byte/semantically identical state (ABA) is intentionally indistinguishable. Tokens are opaque and not persisted to flash.

## Committed-only UCI context

`uci -t` and `uci -P` do not remove the default shared delta search path; `-P` additionally suppresses commit. CAS therefore loads a private dot-free absolute copy and uses only absolute private-file tuples, with `-c` pointing to the private directory so UCI temporary writes stay there. The stock UCI absolute-file backend bypasses shared deltas and the secondary configuration directory. Absolute mutations serialize the private file immediately; the live config is published only after all checks. Cached OpenWrt `CONFIG_*` variables from prior sections are cleared before reloading so removed scalar options cannot survive a committed read.

Shared unsaved Podkop UCI edits are preserved and are excluded from snapshot tokens. Apply returns `uci_pending_changes` while any such edits exist. This explicit restriction is necessary because legacy activation still contains UCI/ubus readers outside CAS's private context. The restriction is checked before validation, before publication, and before activation. If staging appears before activation, rollback restores saved files without invoking a mixed-state reload.

The action lock serializes cooperating Podkop operations. A changed external committed config or runtime identity is detected before publication; a rollback refuses to overwrite a later different external committed file. An uncooperative writer can still race the final compare/rename or modify state during activation. Shell compare-and-rename is not a filesystem CAS. No stronger external-writer atomicity or live-router DNS continuity is claimed.

Publication defers termination signals until whether the file was published is known. An interrupt immediately after rename reports committed rollback honestly and restores the previous saved config/cache. Existing rollback behavior remains covered for activation failures.

## UI behavior

Each draft retains its original section token. Rereads, failed loads, timeouts, service checks, and conflict responses cannot silently advance it. Conflicting desired changes remain visible; explicit review is required before adopting the refreshed base. Removed nodes/sources remain visible conflicts until explicitly discarded. Timeout verification is read-only and never retries mutation. Acknowledged successful submissions clear only their submitted, unchanged keys after a successful reread; newer edits and other sections are preserved. Bundle mismatches require reload/update, without downgrade.

## Resource and delivery boundaries

Admission counts configuration and the complete runtime JSON before copying/parsing; the bounded DNS value is extracted once per operation. Item/evidence sizes and node counts are admitted before canonicalization. Whole-cache backup also has a size and live-memory guard. Fingerprint failures are errors, never empty valid hashes. This uses conservative existing resource budgets, not measured guarantees for every router model.

Legacy .20/.22 and PE .20/.22/.23/.24 contain matching CAS helpers. Both installer mirrors, source retrofit, and standalone apply-v2 retrofit deliver the complete helper/wrapper/dispatcher contract together and reject stale/incomplete source bundles. Versioned UI namespace and release hashes must be regenerated by release integration after this package is combined with other changes.

## Offline verification

`tests/test_subscription_cas_ui.mjs` exercises actual UI handlers. `tests/test_subscription_cas_delivery.sh` exercises both upgrade entrypoints over all included runtime versions and verifies repair, idempotence, complete dependencies and stale-source rejection.

`tests/test_subscription_cas_real.sh` runs real UCI with official OpenWrt shell callbacks and private fixture directories. It has no network/bootstrap behavior. Set `PODKOP_TEST_UCI_EVIDENCE` to a prepared directory containing `build/bin/uci`, `openwrt-functions.sh`, and `openwrt-uci.sh`; otherwise it uses installed UCI/OpenWrt wrappers or explicitly skips when unavailable. Example:

`PODKOP_TEST_UCI_EVIDENCE=/path/to/verified-evidence bash tests/test_subscription_cas_real.sh "$PWD" 0.7.22`

The cloud verification used upstream UCI commit `74f6277aabffc943d026f406df57c22595134c42`, libubox `da2d205a5cf3e877c45a2eec488218cbaf452e7d`, and OpenWrt shell wrappers at `285ff907521717ee7e210663982a328c33588ebe`. The unmodified locally compiled UCI binary SHA-256 was `6c2611f51dcf90e71b5495ed30656ae847fd13e02873e1bb708aeeac4776a091`. Its build is test-only and is not shipped to routers.

Actual activation/reload is substituted in these offline transaction tests. No device, firmware-specific RAM/latency, flash-failure, production traffic, deployment or publication result is implied.
