# Keybridge Connect

Keep Apple Passwords on your Mac and use your passwords on Android. Keybridge transfers supported password records over your local network to an encrypted, read-only Android vault. No cloud account or hosted sync service.

## Install

Download the Mac DMG and Android APK from [Releases](https://github.com/shivexe/keybridge-connect/releases).

- **Mac:** macOS 26 or later. Choose `arm64` for Apple Silicon or `x86_64` for Intel. Drag the app into Applications.
- **Android:** Android 8 or later, with a screen lock enabled. Install the APK and select Keybridge as your autofill service.
- **Mac security warning:** builds are ad-hoc signed, not Apple-notarized. After attempting to open the app, use **System Settings → Privacy & Security → Open Anyway** if offered. Only override the warning for a download you trust. Do not disable Gatekeeper globally.

See [installation and updates](docs/INSTALL.md), including compatibility with earlier development builds.

## Use

1. Open and unlock Keybridge on both devices, connected to the same Wi-Fi or private VPN.
2. On Mac, choose **Pair your phone**. Scan the QR on Android, compare the code, and approve the phone on Mac.
3. Give the Mac app Accessibility access, then choose **Sync now**. Apple handles password authentication.
4. Keep Android open and unlocked while syncing. Once received, passwords are available for offline autofill.

Apple Passwords stays your Mac password manager. Android does not edit passwords or send changes back. Export excludes credentials Apple does not include in CSV, such as passkeys. Custom or protected Android fields may not support autofill.

## Build locally

```sh
git clone https://github.com/shivexe/keybridge-connect.git
cd keybridge-connect
```

### macOS

Install Xcode 26.6 or newer and its command-line tools. No Apple developer account is needed.

```sh
bash apps/macos/build.sh
# Optional: package a DMG for the other supported architecture.
KEYBRIDGE_ARCH=x86_64 bash apps/macos/build.sh --dmg
```

The app is written to `artifacts/`; the script does not replace an installed app. Install and open it normally before granting Accessibility access.

### Android

Install Flutter **3.47.4**, Java **17**, and Android SDK **36**. Configure Flutter with your local Android SDK and accept the SDK licenses.

```sh
cd apps/android
flutter pub get --enforce-lockfile
flutter analyze
flutter build apk --debug
flutter install --debug
```

Flutter supplies the Gradle wrapper on the first build. The APK is in `apps/android/build/app/outputs/flutter-apk/`. For a release APK, provide your signing configuration as described in [Releasing](docs/RELEASING.md); a missing release key is an error.

## Releases

GitHub Actions checks pull requests and `main`. A matching `vX.Y.Z` tag builds ad-hoc Mac DMGs and a permanently signed Android APK, then creates a draft prerelease with SHA-256 checksums. See [Releasing](docs/RELEASING.md) for versioning and signing setup.

## Security

Password exports are processed inside an encrypted temporary Mac volume and removed before delivery. Device pairing and encrypted local storage do not protect a compromised device. This project has not received an independent security audit. Start with a disposable login and read [Security](SECURITY.md) before using real credentials.
