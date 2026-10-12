# Patch delivery and recovery boundaries

This package is prepared source. Offline tests do not establish router health,
flash endurance, client-route continuity, or a successful live deployment.

## Release identity and trust

- `s`, `i` and the update manager resolve a GitHub branch/tag to one full
  40-character commit before retrieving patch release files. Resolution errors
  stop the operation. There is no fallback to the mutable ref.
- The manifest and installer come from that same root; the manager checks `i`
  before invoking it and passes both the immutable asset root and the approved
  manifest SHA-256 into the installer. `s` verifies `i` plus every staged asset.
  The installer validates channel/version and every consumed patch asset.
- GitHub HTTPS plus account/repository integrity remains the trust root. Hashes
  supplied by the same publisher ensure consistency, not independent publisher
  authentication. This is not a signed-release system. A manually downloaded
  bootstrap script must be trusted/verified before executing it; self-checking
  after execution cannot authenticate the bootstrap.
- `file:///absolute/release` and absolute local release roots remain supported.
  The caller owns their provenance. Do not run from a directory another user can
  modify. Relative roots and insecure HTTP delivery are not supported.
- An explicit HTTPS mirror/custom root remains supported when
  `PODKOP_PATCH_MANIFEST_SHA256` is the trusted 64-character lowercase SHA-256 of
  its exact manifest bytes. Supply that pin independently; copying a hash from
  an untrusted mirror provides no authenticity. All patch files must match that
  manifest. A mirror need not implement GitHub's API.
- `PODKOP_PATCH_INSTALLER_URL` is intentionally no longer an independent override:
  installer and assets must belong to one release root. Use
  `PODKOP_PATCH_MANIFEST_URL` (manager), `PODKOP_PATCH_RAW_ROOT` (`s`), or
  `PODKOP_PATCH_RAW_BASE` (`i`) with the contract above.
- TLS verification is never disabled in these delivery paths. DNS bypass uses
  curl `--resolve`, preserving certificate hostname verification. No wget IP /
  Host-header certificate bypass remains in the modified upgrade helpers.

## Lock ownership and interruption

The manager reserves its directory before clearing a log or launching a worker.
A contender never deletes a reservation, even before a PID has been written.
Only a matching owner token releases it. Existing installer mutation locks are
never reclaimed merely because their parent PID disappeared: orphaned helpers
may still be writing. Reboot clears these /tmp locks; same-boot recovery requires
operator verification before removing an orphan. `s` holds a separate staging lock
through installer completion, including background execution. Each run uses a
fresh private staging generation; predictable caller directories are not reused.
Existing state/output paths must be owned by the current user, non-symlink, and
not writable by group/others. Output files are atomically created before use. TERM/INT/HUP
handlers stop and wait for the owned installer before releasing the lock. A
manager timeout watchdog is cancelled and reaped after the command returns.
Deadline expiry returns 124 even if a child handles TERM with success. Timeout is
cooperative: an installer ignoring TERM can outlive the deadline. The manager
waits and retains its lock rather than SIGKILLing an in-progress restoration.

An orphaned installer/manager/staging lock after SIGKILL or power loss is deliberately not
removed automatically. Inspect running processes and any unfinished patch
recovery before manually removing only the verified orphaned lock. Do not delete
another operation's lock based only on a missing or recycled PID. Retained locks
are a conservative stop, not an automatic successful rollback.

## Package boundary

The patch snapshot covers patch-owned files and persistent Podkop state within
one package generation. It does **not** restore packages changed by the official
installer. Legacy's explicitly requested official package installation/update
continues to be a separate risk boundary, including its upstream installer and
package-manager downloads. A failed package phase only restores missing
persistent paths; it does not establish an old working engine/package set.
Prepared PE package migration remains disabled. Do not describe either behavior
as verified package rollback or power-loss-proof recovery.

See the recovery documentation for measured free-space checks, persistent
journal behavior and remaining limitations. Space estimates do not reserve
blocks against unrelated writers; actual write failures must still retain a
recoverable snapshot. No deployment, router restart, package operation, or
network/security setting change was performed during this cloud test work.
