# Redmi AX6 PE fastfix — TEST CANDIDATE

Only **Redmi AX6 / OpenWrt 25.12.5 / APK aarch64**. This is not stable and is not the universal main installer. It does not upgrade Legacy, migrate existing installations, or alter feeds/trust configuration. An exact already-installed copy is a no-op; other existing/partial states are rejected.

## User-run test command

```sh
u=https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/test/redmi-ax6-pe-0724-fastfix/i; wget -O /tmp/pe-test "$u" && sh /tmp/pe-test
```

TLS verification must remain enabled. Review the script before executing if desired. `sh /tmp/pe-test --check` performs only model/version/state checks (no download/install/backup). Normal execution asks you to type `INSTALL` after confirming you have exported a checkpoint and have local LAN/physical recovery access.

The controller stages a pinned candidate commit, verifies every downloaded payload asset and three publisher-pinned APK byte hashes, simulates dependency resolution (including kernel ABI), rejects upgrade/removal/conflict plans, and creates a private persistent `/root/podkop-pe-candidate.*` checkpoint. It requires at least 96 MiB available RAM and 96 MiB free persistent space and performs no automatic cleanup.

The 96 MiB storage floor is deliberately conservative for the compressed APKs, expanded engine, staged payload, dependency growth, checkpoint and margin. Actual free flash on this device has **not** been measured; the controller may refuse a small overlay. This is not permission to delete files or blindly lower the guard. A storage refusal requires a separate measured storage/recovery plan.

**The checkpoint archives `/etc` and APK database state for inspection; it is NOT a complete package/firmware rollback. Never restore the APK database alone.** Export a backup to your computer and have the original matching firmware plus the router's verified physical recovery method before accepting installation. On failure the private staging/checkpoint directory is kept. Do not publish it: it contains private system configuration.

## Packages and hooks

- Podkop and LuCI **0.7.24-r1**, official upstream release.
- **Unofficial** slim Podkop Engine **1.14.2-r14**, exact aarch64_cortex-a53 APK. Not a stock sing-box build or stable promotion.
- Missing official dependencies use the existing signed feeds without `apk upgrade` or feed/key changes. Their normal post-install hooks may execute.
- The three pinned local APKs install with **per-command `--no-network --allow-untrusted --no-scripts`**. Unsigned permission is not persistent; no arbitrary downloaded package is accepted by this offline transaction.
- Pinned package hooks are not executed blindly. `/etc/uci-defaults/99-podkop-engine` and `50_luci-podkop` are relocated to the checkpoint with their SHA receipts so a later reboot cannot silently activate engine defaults. Do not run the deferred engine default script without reviewing activation separately.
- The engine service account is prepared with OpenWrt `group_add`/`user_add`, UID/GID 5566, no login password. UID/GID/name conflicts are rejected before installation; the default non-login shell is retained. No root-user workaround is used.
- The five exact engine features are checked after installation. The original PE adapter is `openwrt/pe-install.sh`, package mutation remains disabled there, and it is always invoked with local verified assets and `PODKOP_PATCH_DEFER_SERVICE_START=1`.
- LuCI RPC/web services may reload during adapter installation. Podkop/engine/failsafe are not started or enabled by this controller. The honest success state is **INSTALLED / STOPPED**, not confirmed routing. Enter subscriptions yourself in LuCI and coordinate activation separately. No reboot is requested.

## After entering subscriptions

In LuCI open **Services → Podkop**, enter your own subscription(s), select the section's nodes/filters and save/apply that selection. Do not post subscription URLs in public reports. After the configuration is saved, the explicit runtime activation command is:

```sh
/usr/bin/podkop start
```

The installed 0.7.24 runtime implements this `start` dispatcher; source inspection confirms the command, **not a successful first activation on Redmi AX6**. It can change DNS/firewall routing. If it reports an error, do not reboot or repeatedly apply: retain the checkpoint and report the error without secrets. Do not run the deferred engine uci-defaults blindly. After activation, verify DNS and a real client website; this publication does not claim those checks passed.

`a`, `m`, and `s` are inherited payload support files, NOT alternate entry points for this candidate. In particular, old migration helpers are not suitable for this fresh 0.7.24 path. Do not run them.

## Verification and limitations

Run on Linux:

```sh
python3 tests/test_fresh_candidate.py
sh -n i
shellcheck -s sh -S error i
node scripts/update-release-hashes.mjs --check
cmp i openwrt/install.sh
```

The fixtures exercise actual controller functions for fresh/exact-existing/reject paths, architecture, checksum failure, dependency failure, and upgrade-plan rejection. They do **not** prove real APK solver behavior, target ABI compatibility, hook suppression, a complete restore, UI or networking on hardware. No live router commands were run for publication. The normal installer independently simulates against your actual installed APK database before mutation and stops if incompatible.
