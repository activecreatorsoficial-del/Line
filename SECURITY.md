# Security policy

Line is preview software. The current 0.9.x series is the focus for security fixes.

## Report a vulnerability

Use GitHub's private vulnerability reporting on this repository's Security tab. Include the affected version, platform, reproduction steps, impact and a minimal demonstration using disposable test files.

Keep vulnerabilities, live invitations, connection responses, temporary codes, keys and personal files out of public issues. A response timeline depends on maintainer availability.

## Verify a transfer

Share invitations and temporary codes through a private channel. Compare the security codes on both screens through an independent trusted channel before accepting a transfer. Peers and the STUN provider can observe connection metadata.

Internet invitations expire after ten minutes. Create a new room when either device changes networks. Android stores incoming files in private app storage before exporting a copy, so allow free space for both copies.

## Release status

Windows preview downloads are unsigned and may trigger SmartScreen. The Android preview uses the existing development signing identity. Public production signing and independent security review remain future work. Check the release's SHA256SUMS.txt before installing a downloaded artifact.

The verification record describes the checks performed and their limits. [Verification record](VERIFICATION.md)
