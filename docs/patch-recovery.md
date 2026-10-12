# Patch snapshot recovery

The installer snapshots patch-owned runtime and persistent paths immediately
before patch mutations. It measures existing snapshot size, downloaded assets,
backup space, staging reserve and destination space with conservative headroom.
This happens after download/package work. It is not a pre-download RAM bound or
an official-package migration space guarantee, and does not reserve blocks.

A data-only journal records state, package generation, exact path layout, DNS
failover/memdoc service state and deferred service-start policy. The snapshot and
state are flushed before the journal rename, then the rename is flushed. This
limits writes to transaction boundaries; no polling or per-file flash journal is
introduced. Hardware power-loss behavior still needs device validation.

Before restoration, a typed inventory checks member paths, file/directory/link
object types, numeric permission modes and exact symlink targets. SHA-256 checks
regular-file contents. Unsupported object types, unavailable metadata tools, or
member names containing newlines fail snapshot preparation before patch writes.
The mode check requires the BusyBox/GNU `stat -c` interface; symlink targets are
encoded as data and never evaluated. Ownership, hard-link relationships, ACLs
and extended attributes are not verified. This is local corruption detection,
not authentication against a privileged writer who can also replace the index.

On the next installer invocation, after acquiring its mutation lock and checking
pending UCI changes, one unfinished patch snapshot is restored before new work.
Failed or interrupted restoration is retryable. Missing/corrupt snapshots,
malformed journals, multiple pending transactions, different layouts and changed
package generations stop recovery and retain the backup. Unresolved journals
are protected from normal backup pruning.

An existing same-boot mutation lock blocks recovery even if its parent PID died;
an orphaned helper might still be writing. After reboot clears /tmp, or an
operator verifies and clears only a genuinely orphaned lock, the same verified
installer may be invoked to recover. No boot-time recovery service is installed.
A changed layout requires the original installer; old unjournaled snapshots need
manual recovery. A release directory/installer should therefore be kept until
the update has completed successfully.

This restores patch files/configuration within a package generation. It does not
roll back official packages, prove end-to-end client routes, or establish
power-loss-proof durability. Prepared PE package migration remains blocked.
