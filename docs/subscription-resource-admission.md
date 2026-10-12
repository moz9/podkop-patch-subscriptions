# Subscription refresh resource admission

This package adds conservative software budgets to subscription refresh. These are not measured guarantees for every router model, nor an automatic reduction of an existing subscription. No node list is silently truncated. A refused refresh retains the previous complete cache and does not apply a new engine configuration.

## Default limits

- Downloaded source body: 1 MiB
- One normalized proxy link: 16 KiB
- Candidate section list: 2,048 rows, counting duplicate rows from different sources before final merging
- Aggregate files in each ingestion/merge admission pass: eight times the configured source-body limit, initially 8 MiB
- Memory estimate: 16 MiB reserve for working services, plus twelve times input/cache byte size, plus 16 KiB per old/candidate node

`MemAvailable` is required. Missing, malformed or insufficient available-memory information refuses refresh. Existing cache bytes are admitted before jq parses that cache; each source is admitted before the per-node parser; the complete candidate is admitted again before deduplication, policy filtering, identity reconciliation and cache promotion. The estimate is deliberately conservative and remains a heuristic. Other processes can allocate memory afterward, and tests here are cloud fixtures rather than hardware OOM proofs.

Curl’s reported failure is now preserved even if it wrote a nonempty response prefix. Wget HTTP/transport failure is handled the same way. Partial responses are not treated as valid smaller subscriptions. Curl receives a size limit, and the downloader child additionally has a file-size limit. File-size block units vary by shell; the cloud shell test permits at most twice the configured body limit before the kernel stops the writer. Target BusyBox behavior still needs device validation. The exact configured body size is checked before parsing. The limit never changes the parent Podkop process’s resource limit.

Each actual downloader command is tracked by PID, Linux process starttime and parent PID. Cancellation terminates and reaps only that owned child; a signal during launch is deferred until identity recording completes. The worker then exits through its original EXIT cleanup. Normal return restores the caller’s signal traps. A monotonic `/proc/uptime` deadline defaults to 45 seconds per command, with a bounded `PODKOP_SUBSCRIPTION_DOWNLOAD_TIMEOUT_SECONDS` override of 1–60. This is not a whole-refresh deadline: proxy/direct fallback, HWID exchange and retries may issue multiple bounded commands.

Base64 decoding only proceeds from bounded input; decoded node/link counts are checked before parsing. Gzip/other archive bodies are not implicitly decompressed by this path. Unsupported or failed decoding preserves the previous list. Link extraction uses one awk process rather than a pipeline whose earlier failure could be hidden; normalization checks its status and refuses a partial output on failure.

## Existing larger subscriptions and administrator overrides

An already-running larger cache is not removed, truncated or disabled. Refresh is refused with a visible reason, leaving that cache and active configuration in place. A cache that exceeds the default node limit may therefore require a reviewed limit override before it can refresh into a smaller list. Do not delete a working cache simply to bypass the refusal.

Administrators may supply these environment values to the refresh process after reviewing available resources:

- `PODKOP_SUBSCRIPTION_MAX_SOURCE_BYTES`: default 1048576; allowed 65536 through 4194304 (64 KiB–4 MiB)
- `PODKOP_SUBSCRIPTION_MAX_NODES`: default 2048; allowed 1 through 8192

These are bounded overrides, not a switch to disable admission. Larger values still require the live memory budget. Invalid, negative, zero, excessive or overflowing values fail closed. Decimal values with a bounded number of leading zeros are normalized. Nothing in this package automatically edits UCI or persists an override. Operators must ensure the intended refresh process actually receives the reviewed environment; setting a shell variable elsewhere is not proof that an RPC worker inherited it.

The 16 KiB per-link cap is fixed. If the provider emits a larger individual config, inspect its format instead of relying on a larger aggregate allowance. A malformed existing JSON cache requires investigation or recovery from a known-good backup, not blind deletion.

## User-visible refusals

Typed errors distinguish excessive source bytes, too many candidate nodes, giant individual links, excessive/malformed old cache, low/unknown memory, invalid limit settings, incomplete HTTP download and failed normalization. The subscription source row and refresh action explain the refusal and retained previous data. A full multi-source refresh may still update healthy peers while retaining a failed source’s cached nodes, following the existing behavior; aggregate-budget refusal keeps the entire previous section cache.

## Boundaries

This package guards refresh ingestion and reconciliation. It does not replace resource checks for independent section-apply operations, probes or updater transactions. It does not prove cache promotion atomicity across several files under disk-full/power-loss faults; that existing transaction boundary remains separate. It does not solve concurrent-tab optimistic concurrency. It does not establish a universally safe router node count or eliminate all collision-heavy reconciliation costs.

Installer integration must deliver the resource helper, downloader, normalizer/extractor, refresh guard and UI together. `podkop-subscription-sources-upgrade.sh` carries the matching retrofit. Legacy installer capability gates must require `subscription_resource_admission_v1`, guarded refresh and preserved downloader status; otherwise an already-patched target could incorrectly skip this upgrade. Regenerate release hashes/versioned UI markers only after all integrated files are final.
