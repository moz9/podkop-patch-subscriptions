# Verified bootstrap for a future authorized release

This source tree is an unpublished integration candidate. Do not install it
using historical branch/CDN one-liners. There is no published release commit or
trusted hash pair supplied here. PE remains prepared; this procedure does not
authorize migration or bypass its package boundary.

## Trust the first executable before running it

Obtain the full 40-character release commit, the SHA-256 of `i`, and the SHA-256
of `openwrt/update-manifest.json` through an independently authenticated release
handoff you trust. Verify the publisher and the channel (Legacy versus PE).
Do not obtain the expected hashes only from the same unverified download or an
untrusted mirror. A hash in that download is consistency data, not independent
authentication. If you cannot establish those trusted inputs, stop.

The installer, manifest and assets must come from that same immutable commit.
The recipe below requires existing trusted curl and sha256sum tools. Do not
bootstrap missing tools by disabling TLS verification. Review package changes,
backup/rollback limits, and the authorized maintenance window before proceeding.

The placeholders are deliberately not executable release defaults. Set the
three variables only after the trusted release handoff above. This recipe is
for a future authorized install, not a task performed by this integration.

```sh
: "${RELEASE_COMMIT:?Set independently verified full release commit}"
: "${EXPECTED_INSTALLER_SHA256:?Set trusted installer SHA-256}"
: "${EXPECTED_MANIFEST_SHA256:?Set trusted manifest SHA-256}"
[ "${#RELEASE_COMMIT}" = 40 ] || exit 1
[ "${#EXPECTED_INSTALLER_SHA256}" = 64 ] || exit 1
[ "${#EXPECTED_MANIFEST_SHA256}" = 64 ] || exit 1
case "$RELEASE_COMMIT$EXPECTED_INSTALLER_SHA256$EXPECTED_MANIFEST_SHA256" in
    *[!0123456789abcdef]*) exit 1 ;;
esac
release_root="https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$RELEASE_COMMIT"
work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 -fSL \
    "$release_root/openwrt/update-manifest.json" -o "$work/manifest.json" || exit 1
printf '%s  %s\n' "$EXPECTED_MANIFEST_SHA256" "$work/manifest.json" | sha256sum -c - || exit 1
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 -fSL \
    "$release_root/i" -o "$work/i" || exit 1
printf '%s  %s\n' "$EXPECTED_INSTALLER_SHA256" "$work/i" | sha256sum -c - || exit 1
PODKOP_PATCH_RAW_BASE="$release_root/openwrt" \
PODKOP_PATCH_MANIFEST_SHA256="$EXPECTED_MANIFEST_SHA256" sh "$work/i"
```

The already verified installer checks its downloaded manifest against the
trusted manifest pin and checks the assets before patch writes. These checks do
not make official-package migration reversible or prove device health.

A CDN/custom HTTPS mirror may be used only for the exact same immutable release
with the same independently verified pins. A DNS bypass must retain certificate
hostname verification (for example curl --resolve with the original HTTPS
hostname); never use a certificate-disabled wget or raw-IP Host-header recipe.
Other helper entrypoints (`a`, `m`, storage preparation) are not covered by the
installer hash above and must be independently verified before execution.

See [delivery trust](update-delivery-trust.md) and [patch recovery](patch-recovery.md)
for the remaining trust, lock, rollback and interruption limits.
