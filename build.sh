#!/bin/bash
# Builds Transcriber.app without Xcode or an Apple Developer account.
#
#   ./build.sh            release build → build/Transcriber.app and build/Transcriber.dmg
#   ./build.sh debug      debug build (no disk image)
#
# By default the app is ad-hoc signed. macOS ties privacy permissions to the code signature,
# so with ad-hoc signing you may be asked to grant them again after each rebuild. To keep them,
# create a self-signed "Code Signing" certificate in Keychain Access and pass its name:
#
#   SIGN_IDENTITY="Transcriber Local" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Transcriber.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Transcriber" "$APP/Contents/MacOS/Transcriber"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Generate the standard macOS icon sizes from the source logo on every build.
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/Branding/transcriber-logo.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/Branding/transcriber-logo.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${SIGN_IDENTITY:-ad-hoc})"

if [ "$CONFIG" = "release" ]; then
    # A disk image with the app and a link to Applications, the usual way to install a Mac app.
    STAGE="$ICON_TMP/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f build/Transcriber.dmg
    hdiutil create -volname "Transcriber" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet build/Transcriber.dmg
    echo "Built build/Transcriber.dmg"
fi
echo "Run it with: open $APP"
