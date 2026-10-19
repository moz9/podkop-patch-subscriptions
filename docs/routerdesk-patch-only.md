# RouterDesk: PE 0.7.24 patch-only channel

The `podkop-pe-0.7.24` branch is for the RouterDesk file-only updater. It requires already installed Podkop and LuCI 0.7.24-r1, Engine package 1.14.2-r14 and running 1.14.2-pdk-r14, on aarch64_cortex-a53 (APK or opkg). It does not migrate PE 0.7.23 or Legacy, install packages, alter configuration, or restart the running proxy.

RouterDesk pins the commit and validates every payload hash. The manifest separately pins its local transaction implementation. It archives the exact replaced files, permissions and absent destinations, verifies an encrypted PC copy, and requires a receipt before writing. A detached watchdog restores files without confirmation within three minutes; early boot also restores an interrupted file transaction. Live configuration, package and process fingerprints must stay unchanged. Pending drafts, an old unresolved task, unsupported init/watchdog integration and insufficient storage prevent an update.

The manifest remains `releaseStatus: prepared` for the older installer/update-manager and package-migration paths. Only the explicit `routerdeskPatch.mode: files-only` contract admits this narrower update. This is not a full installed-state or package backup. The new UI provides separate selection and application of both DNS pairs; applying settings is a separate operation and is not undone by rolling back patch files.

Legacy `main` and the older `podkop-pe` channel are not changed by this publication. A local build/test result does not establish hardware compatibility: use an individually backed-up canary before deploying to other devices.

Home canary found an additional activation boundary: an older unversioned section-runtime context hash does not satisfy the new v2 context guard. Updating files does not migrate that running state. Both-pair selection remains read-only and works; applying new DNS is refused with `runtime_context_upgrade_required`, without replacing the old checkpoint or restarting the proxy. Do not treat a successful patch-file update as proof that DNS application is ready on such a device. A separately validated runtime-state migration is required.
