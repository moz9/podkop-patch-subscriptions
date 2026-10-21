# RouterDesk: PE 0.7.24 patch-only channel

The `podkop-pe-0.7.24` branch is for the RouterDesk file-only updater. It requires already installed Podkop and LuCI 0.7.24-r1, Engine package 1.14.2-r14 and running 1.14.2-pdk-r14, on aarch64_cortex-a53 (APK or opkg). It does not migrate PE 0.7.23 or Legacy, install packages, alter configuration, or restart the running proxy.

RouterDesk pins the commit and validates every payload hash. The manifest separately pins its local transaction implementation. It archives the exact replaced files, permissions and absent destinations, verifies an encrypted PC copy, and requires a receipt before writing. A detached watchdog restores files without confirmation within three minutes; early boot also restores an interrupted file transaction. Live configuration, package and process fingerprints must stay unchanged. Pending drafts, an old unresolved task, unsupported init/watchdog integration and insufficient storage prevent an update.

The stability candidate adds `routerdeskPatch.initIntegration: 1`. Its hash-pinned source upgrader prepares the Podkop and sing-box init handlers on private copies; both files join the same backup/install/rollback inventory. After installation, the coordinator updates only the resident service's trigger list through `service.add`, without an `instances` member. Existing unrelated triggers are preserved, and rollback removes the added handler when the restored init no longer declares it. Proxy process fingerprints must remain unchanged. The relevant procd boundary is [service_update](https://github.com/openwrt/procd/blob/master/service/service.c): instance updates are conditional on the separate instances field. This contract requires a matching RouterDesk coordinator; an older application refuses its hash instead of silently installing an incomplete fix.

The manifest remains `releaseStatus: prepared` for the older installer/update-manager and package-migration paths. Only the explicit `routerdeskPatch.mode: files-only` contract admits this narrower update. This is not a full installed-state or package backup. The new UI provides separate selection and application of both DNS pairs; applying settings is a separate operation and is not undone by rolling back patch files.

Legacy `main` and the older `podkop-pe` channel are not changed by this publication. A local build/test result does not establish hardware compatibility: use an individually backed-up canary before deploying to other devices.

An older unversioned section-runtime checkpoint may differ from current desired settings. The file update does not migrate it. A separate DNS application can now continue an exact section-admitted graph only after verifying its compound hash, graph aliases, required-service sets, admitted observations, and both live and archived local rules. It changes the selected DNS pair(s) only; the old global checkpoint, admission policy, routes, proxy membership and unrelated saved/draft preferences remain untouched. It does not certify those global preferences as active or bypass the full-restart gate. Missing scoped provenance, v2 context drift, changed evidence/rules or conflicting DNS drafts still fail before mutation.

DNS rollback restores the exact prior configuration and admission snapshot. Its final check binds the restored UCI digest, not the just-reverted candidate, and still rejects concurrent foreign edits. Patch-file rollback remains separate. Local/CI results alone do not prove hardware activation: complete the home-only live cycle before recommending deployment.

### v22: diagnostic-cache independence and update status

For historical hash-only snapshots, DNS-only continuation authenticates the exact admitted runtime and preserves the historical service digest; it does not reconstruct old observations from today's mutable cache or certify new service results. Cache refresh, unknown observations and eviction do not revoke that existing admission. Explicit observed denials for admitted IDs and required services still refuse the transaction, as do malformed/unsafe cache files. Snapshots containing frozen evidence still require its exact digest. No proxy is admitted, removed or reselected by this exception, and restart/rebuild gates are unchanged.

LuCI reads the PE 0.7.24 channel, recognizes same-day `-routerdesk` revisions, clears obsolete version/update permissions after failed checks or external installation, and directs newer file-only releases to RouterDesk. A current file-only release is shown as current. The generic installer and package migration remain disabled.

### Stability candidate v24

The manual DNS selector reads the bounded immutable package catalog once when
the dialog opens. It no longer needs a previous measurement cache. Catalog
entries remain explicitly unmeasured and cannot grant apply permission; a
current backend proof is still required. Native two-pair selection does not
display an empty historical measurement table as its result.

Fresh rollback workers recover the transaction's recorded file paths and bind
policy checks to its committed UCI file. Unrelated shared drafts are preserved,
not used as restored-policy evidence. Concurrent committed edits still stop
rollback before overwriting those edits.

This candidate is published separately from the fleet channels. A successful
home canary does not establish Legacy or PE 0.7.23 hardware compatibility, a
logged-in application path from a LAN client, or power-loss recovery.

### Stability candidate v25: manual nodes with subscription service filters

Manual links are separate from subscription source/tag selection. They are not
exempt from required-service evidence: the existing service-check buttons now
include them, and their exact URI identity is resolved without adding them to
the subscription catalog. Required checks must pass before activation. Missing,
expired, denied or changed-URI evidence still blocks application before stopping
the working service. No throughput benchmark or automatic background apply is
introduced.

The frozen admission snapshot includes both subscription and manual IDs, exact
link hashes and measured evidence. Existing runtime/configuration continuity,
DNS transactions and rollback therefore retain their checks instead of using a
blanket manual-link exception. A successful activation is left in place; a
test-only rollback is not part of this candidate's acceptance procedure.
