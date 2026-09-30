# Security

Keybridge is a personal password companion, not an independently audited password manager. Verify a disposable login before using real credentials. Do not pair with a device you do not control.

- Pairing uses a short-lived QR and an explicit comparison-code approval. Treat the QR as a secret.
- Sync uses pinned TLS and authenticated encrypted snapshots. The desktop reports delivery after the phone acknowledges a committed snapshot.
- The Mac export is plaintext through its mounted encrypted volume while processing. That protects the backing storage, not against other software running as you. Cleanup removes only Keybridge-owned files; it never empties Trash. Crash recovery runs when the app next starts. Deletion is not a guarantee of physical erasure from SSDs or backups.
- Public Mac builds use the login Keychain and explicitly authenticate the user through macOS before unlocking. This differs from a provisioned app's user-presence-protected Data Protection Keychain. The login Keychain's access controls and OS permissions still apply; the app does not claim hardware-enforced per-use authentication for this backend.
- Android stores its vault encrypted with a device-local Keystore key and requires authentication to unlock. Hardware protection varies by device. Backup and device transfer are disabled for vault data.
- Revoking a phone blocks future synchronization; it cannot remotely erase passwords already received by an offline device.
- Ad-hoc Mac signatures do not verify a publisher identity and may cause renewed permission prompts after updates. The app is not notarized by Apple.
- Clipboard copying is optional and exposes a password to clipboard readers. Clearing only works while Keybridge is running and while its entry is unchanged.

Report vulnerabilities using the repository's **Security → Report a vulnerability** page. Do not include real passwords, QR invitations, vault files, private keys or signing credentials in public issues.
