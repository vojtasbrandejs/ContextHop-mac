#!/bin/bash

set -euo pipefail

APP_NAME="ContextHop.app"
EXECUTABLE_NAME="ContextHop"
BUNDLE_IDENTIFIER="com.vojta.contexthop"
REPOSITORY="vojtasbrandejs/ContextHop-mac"
SOURCE_REF="${CONTEXTHOP_SOURCE_REF:-v1.0.2}"
SOURCE_ARCHIVE_URL="${CONTEXTHOP_SOURCE_ARCHIVE_URL:-https://github.com/$REPOSITORY/archive/refs/tags/$SOURCE_REF.tar.gz}"
INSTALL_DIR="${CONTEXTHOP_INSTALL_DIR:-/Applications}"
LAUNCH_AFTER_INSTALL="${CONTEXTHOP_LAUNCH_AFTER_INSTALL:-1}"
TESTING="${CONTEXTHOP_INSTALLER_TESTING:-0}"
WORK_DIR="$(/usr/bin/mktemp -d -t contexthop-source-install)"
ARCHIVE="$WORK_DIR/source.tar.gz"
SOURCE_DIR="$WORK_DIR/source"
TARGET_APP="$INSTALL_DIR/$APP_NAME"
BACKUP_APP="$WORK_DIR/previous-$APP_NAME"
PREVIOUS_APP_MOVED=0
INSTALL_STARTED=0
INSTALL_COMPLETE=0

cleanup() {
    local restored=1
    if [[ "$INSTALL_COMPLETE" != "1" ]]; then
        if [[ "$INSTALL_STARTED" == "1" ]]; then
            /bin/rm -rf "$TARGET_APP"
        fi
        if [[ "$PREVIOUS_APP_MOVED" == "1" && -e "$BACKUP_APP" ]]; then
            /bin/mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || restored=0
        fi
    fi
    if [[ "$restored" == "1" ]]; then
        /bin/rm -rf "$WORK_DIR"
    else
        echo "Could not restore the previous app. Backup kept in $WORK_DIR." >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "ContextHop installer: $*" >&2
    exit 1
}

download() {
    local url="$1"
    local destination="$2"

    if [[ "$url" == https://* ]]; then
        /usr/bin/curl \
            --proto "=https" \
            --tlsv1.2 \
            --fail \
            --location \
            --silent \
            --show-error \
            --retry 3 \
            --output "$destination" \
            "$url"
    elif [[ "$TESTING" == "1" && "$url" == file://* ]]; then
        /usr/bin/curl \
            --fail \
            --location \
            --silent \
            --show-error \
            --output "$destination" \
            "$url"
    else
        fail "refusing a source URL that is not HTTPS"
    fi
}

bundle_identifier() {
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleIdentifier" \
        "$1/Contents/Info.plist" \
        2>/dev/null || true
}

stop_running_app() {
    /usr/bin/pkill -TERM -x "$EXECUTABLE_NAME" 2>/dev/null || true
    for _ in {1..30}; do
        if ! /usr/bin/pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
            return
        fi
        /bin/sleep 0.1
    done
    fail "ContextHop is still running; quit it and run the command again"
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "macOS is required"
MACOS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
(( MACOS_MAJOR >= 14 )) || fail "macOS 14 Sonoma or newer is required"

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    if [[ "$TESTING" != "1" ]]; then
        /usr/bin/xcode-select --install 2>/dev/null || true
    fi
    fail "Apple Command Line Tools are required. Finish their free installation, then run this command again."
fi

SWIFT_MAJOR="$(/usr/bin/xcrun swift --version | /usr/bin/awk '/Swift version/ { split($4, version, "."); print version[1]; exit }')"
[[ "$SWIFT_MAJOR" =~ ^[0-9]+$ ]] && (( SWIFT_MAJOR >= 6 )) \
    || fail "Swift 6 or newer is required. Update Apple Command Line Tools and try again."

echo "Downloading ContextHop source $SOURCE_REF from GitHub…"
download "$SOURCE_ARCHIVE_URL" "$ARCHIVE"

/bin/mkdir -p "$SOURCE_DIR"
/usr/bin/tar -xzf "$ARCHIVE" --strip-components 1 -C "$SOURCE_DIR"

for required_path in \
    Package.swift \
    Sources/ContextHop \
    Sources/ContextHopKit \
    assets/icon-1024.png \
    LICENSE \
    scripts/make-app.sh; do
    [[ -e "$SOURCE_DIR/$required_path" ]] \
        || fail "the source archive is missing $required_path"
done

echo "Building ContextHop locally on this Mac…"
(
    cd "$SOURCE_DIR"
    CONTEXTHOP_PACKAGE_DISTRIBUTION=0 ./scripts/make-app.sh
)

SOURCE_APP="$SOURCE_DIR/.build/$APP_NAME"
[[ -d "$SOURCE_APP" ]] || fail "the local build did not create $APP_NAME"
[[ -x "$SOURCE_APP/Contents/MacOS/$EXECUTABLE_NAME" ]] \
    || fail "the local build is missing its executable"
[[ "$(bundle_identifier "$SOURCE_APP")" == "$BUNDLE_IDENTIFIER" ]] \
    || fail "the local build has an unexpected bundle identifier"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" \
    || fail "the local build has an invalid code signature"
/usr/bin/lipo "$SOURCE_APP/Contents/MacOS/$EXECUTABLE_NAME" \
    -verify_arch arm64 x86_64 \
    || fail "the local build is not Universal 2"

if [[ "$INSTALL_DIR" == "/Applications" && ! -w "$INSTALL_DIR" ]]; then
    INSTALL_DIR="$HOME/Applications"
    TARGET_APP="$INSTALL_DIR/$APP_NAME"
    echo "Using $INSTALL_DIR because /Applications is not writable."
fi

/bin/mkdir -p "$INSTALL_DIR" || fail "could not create $INSTALL_DIR"
[[ -w "$INSTALL_DIR" ]] || fail "cannot write to $INSTALL_DIR"

if [[ "$TESTING" != "1" ]]; then
    stop_running_app
fi

if [[ -e "$TARGET_APP" ]]; then
    [[ "$(bundle_identifier "$TARGET_APP")" == "$BUNDLE_IDENTIFIER" ]] \
        || fail "$TARGET_APP belongs to a different application"
    PREVIOUS_APP_MOVED=1
    if ! /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
        PREVIOUS_APP_MOVED=0
        fail "could not replace the existing app"
    fi
fi

INSTALL_STARTED=1
if ! COPYFILE_DISABLE=1 /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"; then
    fail "installation failed"
fi

if ! /usr/bin/codesign --verify --deep --strict "$TARGET_APP"; then
    fail "the installed app failed verification"
fi
if /usr/bin/xattr -p com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1; then
    fail "the locally built app unexpectedly has a quarantine attribute"
fi

INSTALL_COMPLETE=1
/bin/rm -rf "$BACKUP_APP"

echo "Installed the locally built ContextHop app in $INSTALL_DIR"
if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
    /usr/bin/open "$TARGET_APP"
    echo "ContextHop is running in the menu bar."
fi
