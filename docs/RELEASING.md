# Releasing

## Version

`VERSION` contains `X.Y.Z+BUILD`. Keep the Android `pubspec.yaml` version and Mac `Info.plist` version/build in sync. Increase BUILD for every Android update. CI rejects disagreement.

## Android signing

All public APKs must use the same permanent release keystore. Back it up securely along with its passwords; losing it prevents normal updates. Never commit the keystore or passwords, and never use the development debug key for public releases.

For local release builds, create an untracked properties file outside the repository:

```properties
storeFile=/absolute/path/to/your-release.jks
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=YOUR_ALIAS
```

Set restrictive file permissions, then build:

```sh
cd apps/android
flutter pub get --enforce-lockfile
KEYBRIDGE_SIGNING_PROPERTIES=/absolute/path/to/signing.properties flutter build apk --release
```

For GitHub Actions, the `release` environment contains `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD` and `ANDROID_KEY_ALIAS`. Environment variable `ANDROID_SIGNING_CERT_SHA256` pins the expected public signing-certificate fingerprint. Restrict that environment to version tags. Secrets are decoded only on the release runner and are never uploaded as artifacts. Missing credentials or a fingerprint mismatch fail the release.

## Mac packaging

The build script compiles the pinned Swift dependencies, creates the app bundle, applies an ad-hoc signature, and verifies it. It requires no Apple account and performs no notarization. Run `KEYBRIDGE_ARCH=arm64 bash apps/macos/build.sh --dmg`, or select `x86_64` for Intel.

## Publish

1. Update version fields and review changes. Keep private runtime/tool directories and signing files out of the commit.
2. Push `main` and confirm CI succeeds.
3. Tag that commit: `git tag vX.Y.Z`, then `git push origin vX.Y.Z`.
4. Release Actions builds both Mac architectures and the signed Android APK. After every job succeeds, it creates a **draft prerelease** with generated release notes and SHA-256 checksums. Review installation and update behaviour, then publish the draft on GitHub.

Do not claim that a successful CI build validates Apple Passwords UI automation, a physical Android device or all OS permission flows. CI does not export passwords, access a personal vault or require signing secrets on pull requests. Never replace assets on an already published version; issue a new version instead.
