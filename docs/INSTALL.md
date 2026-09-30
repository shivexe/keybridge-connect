# Installation and updates

## Mac

Use the DMG matching your processor: `arm64` for Apple Silicon, `x86_64` for Intel. macOS 26 or later is required. Drag **Keybridge Connect.app** into Applications and open it.

These builds are ad-hoc signed and are not notarized by Apple. If macOS blocks opening, first attempt to launch the app, then look for **Open Anyway** under **System Settings → Privacy & Security**. Confirm only if you trust the release source. Managed devices may disallow this override. Do not disable Gatekeeper or run a downloaded script to bypass it. [Apple's instructions](https://support.apple.com/en-us/102445).

Grant **Accessibility** access to this exact installed app when prompted. Allow local-network access where macOS requests it. Apple Passwords remains the Mac autofill provider; Keybridge never needs your Apple ID password or your Mac login password entered into its own UI.

The public ad-hoc build stores its encrypted state separately under `~/Library/Application Support/Keybridge Connect Community`. It uses the login Keychain plus macOS authentication instead of the development build's provisioned Data Protection Keychain. Existing development state is not read, replaced or migrated automatically. Pair the public build again and re-export from Apple Passwords; preserve the development installation/data until this succeeds.

For updates, quit Keybridge before replacing the application. An ad-hoc signature changes with the executable, so macOS may require renewed Accessibility or Keychain approval. If permissions stop matching, remove only the old Keybridge entry from Accessibility settings and add the installed app again. Never reset all privacy permissions.

## Android

Download the signed APK, allow installation from the app opening that file, install it, and enable a device screen lock. Use Keybridge's settings to enable autofill. Android 14+ can also enable the password credential provider. Accessibility filling is optional and requires an explicit permission grant.

Install future release APKs over the existing release installation. Do not uninstall first: uninstalling removes the app's local vault and keys. GitHub releases use one permanent release key and increasing version codes.

Earlier local development APKs may use a different signing key. Android will reject an in-place update with a different signer; this does not mean the release APK is corrupt. Keep the old app until you are ready to clear its state and pair again. Confirm your passwords remain in Apple Passwords before intentionally uninstalling a development build.

## Pair and sync

Connect both devices to the same network or a private VPN. Unlock both apps. Display the Mac pairing QR, scan it on Android, compare the six-digit code and approve on Mac. Keep Android open and unlocked to receive updates; autofill subsequently uses its offline vault.

Choose **Sync now** on Mac. Complete Apple's authentication if requested; no manual export-file selection should be necessary. A waiting-for-phone status means the export is ready, not yet delivered. If an error occurs, preserve the existing vault and use the app's recovery controls rather than manually deleting its storage.
