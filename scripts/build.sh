#!/bin/zsh
# Builds build/Isle.app for Apple silicon.
#
#   scripts/build.sh              build (ad-hoc signed)
#   scripts/build.sh --install    build, copy to /Applications, relaunch
#   scripts/build.sh --release    test, build, sign, zip (and notarize if configured)
#
# Release signing / notarization (optional):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<profile saved with `xcrun notarytool store-credentials`>
set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/build/Isle.app"
MODE=${1:-}
cd "$ROOT"

# Version: latest tag (v1.2.3 → 1.2.3), build number: commit count.
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-1.0.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

if [[ "$MODE" == "--release" ]]; then
    echo "› Running tests"
    swift test
fi

echo "› Compiling Isle $VERSION ($BUILD)"
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

echo "› Compiling Now Playing helper"
mkdir -p .build/helper
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch arm64e -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit \
    Helpers/MediaRemoteBridge.m -o .build/helper/libIsleMediaRemote.dylib

echo "› Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Isle" "$APP/Contents/MacOS/Isle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp .build/helper/libIsleMediaRemote.dylib Helpers/mediaremote.pl "$APP/Contents/Resources/"

if [[ ! -f .build/AppIcon.icns || scripts/make-icon.swift -nt .build/AppIcon.icns ]]; then
    echo "› Rendering icon"
    rm -rf .build/AppIcon.iconset
    swift scripts/make-icon.swift .build/AppIcon.iconset
    iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "› Signing with $SIGN_IDENTITY (hardened runtime)"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Resources/libIsleMediaRemote.dylib"
    codesign --force --timestamp --options runtime --entitlements Resources/Isle.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
else
    echo "› Signing (ad-hoc)"
    codesign --force --sign - "$APP/Contents/Resources/libIsleMediaRemote.dylib"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "✓ $APP"

case "$MODE" in
--install)
    pkill -x Isle 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Isle.app
    cp -R "$APP" /Applications/Isle.app
    open /Applications/Isle.app
    echo "✓ Installed to /Applications and launched"
    ;;
--release)
    ZIP="$ROOT/build/Isle-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
        echo "› Notarizing"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
    else
        echo "  (not notarized: set SIGN_IDENTITY and NOTARY_PROFILE to notarize)"
    fi
    echo "✓ $ZIP"
    ;;
esac
