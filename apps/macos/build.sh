#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS and Xcode are required.' >&2; exit 2; }
cd "$(dirname "$0")"
KB_PROJECT="$(cd ../.. && pwd)"
KB_VERSION="$(tr -d '\r\n' < "$KB_PROJECT/VERSION")"
[[ "$KB_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || { echo 'Invalid VERSION.' >&2; exit 2; }
KB_ARCH="${KEYBRIDGE_ARCH:-$(uname -m)}"
[[ "$KB_ARCH" == arm64 || "$KB_ARCH" == x86_64 ]] || { echo 'Unsupported architecture.' >&2; exit 2; }
KB_APP="$KB_PROJECT/artifacts/Keybridge Connect-$KB_ARCH.app"
KB_BUILD="$KB_PROJECT/.work/swift-$KB_ARCH"
mkdir -p "$KB_PROJECT/.work" "$KB_APP/Contents/MacOS" "$KB_APP/Contents/Resources"
KB_FLAGS=(-c release --arch "$KB_ARCH" --scratch-path "$KB_BUILD" --disable-automatic-resolution -Xswiftc -DKEYBRIDGE_COMMUNITY)
swift build "${KB_FLAGS[@]}"
KB_BIN="$(swift build "${KB_FLAGS[@]}" --show-bin-path)"
swift Icon.swift "$KB_PROJECT/.work/Keybridge.iconset"
iconutil -c icns "$KB_PROJECT/.work/Keybridge.iconset" -o "$KB_APP/Contents/Resources/Keybridge.icns"
cp "$KB_BIN/KeybridgeConnect" "$KB_APP/Contents/MacOS/KeybridgeConnect"
cp Info.plist "$KB_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${KB_VERSION%+*}" "$KB_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${KB_VERSION#*+}" "$KB_APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none --options runtime "$KB_APP"
codesign --verify --deep --strict "$KB_APP"
if [[ "${1:-}" == --dmg ]]; then
  KB_STAGE="$(mktemp -d "$KB_PROJECT/.work/dmg-stage.XXXXXX")"
  ditto "$KB_APP" "$KB_STAGE/Keybridge Connect.app"
  ln -s /Applications "$KB_STAGE/Applications"
  hdiutil create -volname 'Keybridge Connect' -srcfolder "$KB_STAGE" -ov -format UDZO \
    "$KB_PROJECT/artifacts/Keybridge-Connect-${KB_VERSION%+*}-macOS-$KB_ARCH.dmg"
fi
printf 'Built (ad-hoc signed, not notarized): %s\n' "$KB_APP"
