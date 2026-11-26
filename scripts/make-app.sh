#!/bin/bash
# Build, sign, and package a Universal 2 ContextHop release.
#
# By default this creates:
#   .build/ContextHop.app
#   dist/ContextHop.app.zip (+ SHA-256)
#   dist/ContextHop.dmg     (+ SHA-256)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${CONTEXTHOP_VERSION:-1.0.3}"
BUILD_NUMBER="${CONTEXTHOP_BUILD_NUMBER:-4}"
ARM64_TRIPLE="arm64-apple-macosx14.0"
X86_64_TRIPLE="x86_64-apple-macosx14.0"
APP="$ROOT/.build/ContextHop.app"
ARCHIVE="$ROOT/dist/ContextHop.app.zip"
ARCHIVE_CHECKSUM="$ARCHIVE.sha256"
DMG="$ROOT/dist/ContextHop.dmg"
DMG_CHECKSUM="$DMG.sha256"
STAGING_ROOT="$(/usr/bin/mktemp -d -t contexthop-build)"
DMG_SOURCE="$STAGING_ROOT/dmg"
SIGNING_IDENTITY="${CONTEXTHOP_SIGNING_IDENTITY:-}"
PACKAGE_DISTRIBUTION="${CONTEXTHOP_PACKAGE_DISTRIBUTION:-1}"

cleanup() {
    /bin/rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

cd "$ROOT"
ARM64_BUILD_PATH="$(swift build -c release --triple "$ARM64_TRIPLE" --product ContextHop --show-bin-path)"
X86_64_BUILD_PATH="$(swift build -c release --triple "$X86_64_TRIPLE" --product ContextHop --show-bin-path)"

echo "==> building ContextHop for arm64"
swift build -c release --triple "$ARM64_TRIPLE" --product ContextHop
echo "==> building ContextHop for x86_64"
swift build -c release --triple "$X86_64_TRIPLE" --product ContextHop

/bin/rm -rf \
    "$APP" \
    "$ARCHIVE" \
    "$ARCHIVE_CHECKSUM" \
    "$DMG" \
    "$DMG_CHECKSUM" \
    "$ROOT/dist/ContextHop.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"

echo "==> assembling Universal 2 app"
/usr/bin/lipo -create \
    "$ARM64_BUILD_PATH/ContextHop" \
    "$X86_64_BUILD_PATH/ContextHop" \
    -output "$APP/Contents/MacOS/ContextHop"
/usr/bin/lipo "$APP/Contents/MacOS/ContextHop" -verify_arch arm64 x86_64
/bin/chmod 755 "$APP/Contents/MacOS/ContextHop"

if [[ -f "$ROOT/assets/icon-1024.png" ]]; then
    ICONSET="$STAGING_ROOT/AppIcon.iconset"
    /bin/mkdir -p "$ICONSET"
    while read -r filename size; do
        /usr/bin/sips -z "$size" "$size" "$ROOT/assets/icon-1024.png" \
            --out "$ICONSET/$filename" >/dev/null
    done <<'EOF'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
EOF
    /usr/bin/iconutil -c icns "$ICONSET" \
        -o "$APP/Contents/Resources/AppIcon.icns"
fi

/bin/cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

/bin/cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>ContextHop</string>
	<key>CFBundleDisplayName</key>
	<string>ContextHop</string>
	<key>CFBundleIdentifier</key>
	<string>com.vojta.contexthop</string>
	<key>CFBundleExecutable</key>
	<string>ContextHop</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright (c) 2026 Vojtěch Brandejs. MIT licensed.</string>
	<key>NSAccessibilityUsageDescription</key>
	<string>ContextHop uses Accessibility to read the title of the open conversation in Codex or Claude Desktop, so Copy context can identify the chat on screen. ContextHop never types or clicks in other apps.</string>
</dict>
</plist>
PLIST

echo "==> signing app"
/usr/bin/xattr -cr "$APP"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP"
    SIGNING_DESCRIPTION="Developer ID ($SIGNING_IDENTITY), hardened runtime and secure timestamp"
else
    /usr/bin/codesign --force --deep --sign - "$APP"
    SIGNING_DESCRIPTION="ad-hoc local signature"
fi
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "==> built $APP"
echo "    signing: $SIGNING_DESCRIPTION"

if [[ "$PACKAGE_DISTRIBUTION" == "1" ]]; then
    echo "==> creating ZIP and DMG"
    COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
    /bin/mkdir -p "$DMG_SOURCE"
    COPYFILE_DISABLE=1 /usr/bin/ditto "$APP" "$DMG_SOURCE/ContextHop.app"
    /bin/cp "$ROOT/LICENSE" "$DMG_SOURCE/LICENSE.txt"
    /bin/ln -s /Applications "$DMG_SOURCE/Applications"
    /usr/bin/hdiutil create \
        -quiet \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        -volname "ContextHop" \
        -srcfolder "$DMG_SOURCE" \
        "$DMG"

    (
        cd "$ROOT/dist"
        /usr/bin/shasum -a 256 "ContextHop.app.zip" > "ContextHop.app.zip.sha256"
        /usr/bin/shasum -a 256 "ContextHop.dmg" > "ContextHop.dmg.sha256"
    )
    echo "    packages: $DMG and $ARCHIVE"
fi
