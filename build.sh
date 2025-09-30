#!/bin/bash
set -euo pipefail

# PowerTop / grok-usage style: compile app under finddup/, emit .app + .zip
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$PROJECT_DIR/finddup"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Fast Duplicate Finder"
EXEC_NAME="Fast Duplicate Finder"
ZIP_NAME="FastDuplicateFinder.zip"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
ENTITLEMENTS="$APP_SRC/finddup.entitlements"
INFO_PLIST="$APP_SRC/Info.plist"

echo "=== Building $APP_NAME ==="
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo '?')"
echo "Version: $APP_VERSION"

if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
    SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
else
    SDK="$(xcrun --show-sdk-path)"
    SWIFTC="swiftc"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$APP_SRC" -name '*.swift' | sort)
if [ ${#SWIFT_FILES[@]} -eq 0 ]; then
    echo "error: no Swift sources under $APP_SRC" >&2
    exit 1
fi

echo "Compiling ${#SWIFT_FILES[@]} sources…"
"$SWIFTC" \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework CryptoKit \
    -framework Combine \
    -framework UniformTypeIdentifiers \
    -parse-as-library \
    -O \
    -o "$BUILD_DIR/$EXEC_NAME" \
    "${SWIFT_FILES[@]}"

echo "Creating app bundle…"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

mv "$BUILD_DIR/$EXEC_NAME" "$EXECUTABLE"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"

# Localizations
for lproj in en.lproj zh-Hans.lproj; do
    if [ -d "$APP_SRC/$lproj" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/$lproj"
        cp "$APP_SRC/$lproj/"*.strings "$APP_BUNDLE/Contents/Resources/$lproj/" 2>/dev/null || true
        echo "→ Bundled $lproj"
    fi
done

# App icon (.icns)
echo "Building AppIcon.icns…"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
ICONSET_SRC="$APP_SRC/Assets.xcassets/AppIcon.appiconset"
MISSING_ICONS=0
for f in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
         icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
         icon_512x512.png icon_512x512@2x.png; do
    if [ -f "$ICONSET_SRC/$f" ]; then
        cp "$ICONSET_SRC/$f" "$ICONSET_DIR/$f"
    else
        echo "warning: missing icon $f" >&2
        MISSING_ICONS=1
    fi
done
if [ "$MISSING_ICONS" -eq 0 ]; then
    if ! iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"; then
        echo "error: iconutil failed to create AppIcon.icns" >&2
        rm -rf "$(dirname "$ICONSET_DIR")"
        exit 1
    fi
    echo "→ AppIcon.icns ready"
else
    echo "error: incomplete AppIcon.appiconset; cannot build AppIcon.icns" >&2
    rm -rf "$(dirname "$ICONSET_DIR")"
    exit 1
fi
rm -rf "$(dirname "$ICONSET_DIR")"

# Ad-hoc sign with sandbox entitlements (user-selected files)
if command -v codesign >/dev/null 2>&1; then
    if [ -f "$ENTITLEMENTS" ]; then
        codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null 2>&1 || true
    else
        codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
    fi
fi

ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "=== Build complete ==="
echo "App bundle: $APP_BUNDLE"
echo "Zip archive: $ZIP_PATH"
echo ""
echo "To run: open \"$APP_BUNDLE\""
echo "Install: cp -R \"$APP_BUNDLE\" /Applications/"
