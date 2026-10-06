#!/usr/bin/env bash
# Archive the Burrow iOS app (com.kobo-ai.burrow) and upload it to App Store Connect (TestFlight).
#
# Rock only. Adapted from cloudplay's apple-tv/scripts/archive_for_testflight.sh
# and upload_to_testflight.sh: same keychain unlock, same file-backed build
# counter, same xcodegen regenerate, same automatic signing for team
# XJ2GLJ9ST2. Two differences:
#   - the export uses clients/ios/ExportOptions.plist with destination
#     "upload", so `xcodebuild -exportArchive` uploads the build itself (no
#     separate altool step);
#   - archive and export authenticate with the ASC API key
#     (-authenticationKey*), because rock has no Apple Distribution
#     certificate. Distribution signing is cloud-managed, and
#     -allowProvisioningUpdates registers the App, share and widgets bundle
#     IDs with Push Notifications and App Groups from their entitlements.
#     That needs an Admin-role key and an in-effect ASC agreement.
#
# Reads (never prints) ~/.config/suite-ios-build/asc.env (ASC_API_KEY_ID,
# ASC_API_ISSUER), the key at ~/private_keys/AuthKey_<id>.p8, and the
# keychain passphrase at ~/.config/cloudplay-tv-build/passphrase.
#
# Build number: ~/.config/suite-ios-build/buildnumber, incremented on every
# archive (Apple rejects a duplicate CFBundleVersion). The marketing version
# stays at project.yml's MARKETING_VERSION ("1.2"), so WHATSNEW.md's top
# section is "## v1.2" until a semantic bump.
#
# After the upload, scripts/set_testflight_notes.py sets "What to Test" from
# WHATSNEW.md and adds the build to the internal group "Suite internal".
#
# Usage:
#   clients/ios/scripts/testflight.sh                 # archive, upload, notes
#   clients/ios/scripts/testflight.sh --archive-only  # stop after the archive
#   clients/ios/scripts/testflight.sh --no-notes      # skip the notes helper
set -euo pipefail

TEAM_ID="${TEAM_ID:-XJ2GLJ9ST2}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/suite-ios-build}"
ASC_ENV_FILE="${ASC_ENV_FILE:-$CONFIG_DIR/asc.env}"
BUILD_NUMBER_FILE="$CONFIG_DIR/buildnumber"
PASS_FILE="${PASS_FILE:-$HOME/.config/cloudplay-tv-build/passphrase}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Dev/build/suite-ios}"
XCODEGEN="${XCODEGEN:-$HOME/.local/bin/xcodegen}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" # clients/ios
APP_DIR="$IOS_ROOT/ios/App"
EXPORT_PLIST="$IOS_ROOT/ExportOptions.plist"

ARCHIVE_ONLY=0
NOTES=1
for arg in "$@"; do
    case "$arg" in
        --archive-only) ARCHIVE_ONLY=1 ;;
        --no-notes) NOTES=0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

for f in "$ASC_ENV_FILE" "$PASS_FILE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f missing" >&2
        exit 1
    fi
done

# shellcheck disable=SC1090
. "$ASC_ENV_FILE"
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID not set in $ASC_ENV_FILE}"
: "${ASC_API_ISSUER:?ASC_API_ISSUER not set in $ASC_ENV_FILE}"
ASC_KEY_PATH="$HOME/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
if [ ! -f "$ASC_KEY_PATH" ]; then
    echo "ERROR: ASC API key file missing under ~/private_keys/" >&2
    exit 1
fi
AUTH_ARGS=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_API_KEY_ID"
    -authenticationKeyIssuerID "$ASC_API_ISSUER"
)

# 1. Unlock the keychain so codesign works over SSH / without a GUI session.
security unlock-keychain -p "$(cat "$PASS_FILE")" \
    "$HOME/Library/Keychains/login.keychain-db"

# 2. Web assets. ios/App/App/public is gitignored; copy www into it.
if [ ! -f "$APP_DIR/App/public/index.html" ]; then
    (cd "$IOS_ROOT" && npx cap copy ios)
fi

# 3. Regenerate the xcodeproj from project.yml.
(cd "$APP_DIR" && "$XCODEGEN" generate >/dev/null)

# Fail before spending a build number if WHATSNEW.md doesn't match.
MARKETING_VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"([^"]+)".*/\1/p' "$APP_DIR/project.yml" | head -1)"
if [ -z "$MARKETING_VERSION" ]; then
    echo "ERROR: could not parse MARKETING_VERSION from project.yml" >&2
    exit 1
fi
if [ "$NOTES" = "1" ]; then
    /usr/bin/python3 "$SCRIPT_DIR/set_testflight_notes.py" --check "$MARKETING_VERSION"
fi

# 4. Build number: strictly monotonic per host.
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [ -f "$BUILD_NUMBER_FILE" ]; then
    BUILD_NUMBER="$(($(cat "$BUILD_NUMBER_FILE") + 1))"
else
    BUILD_NUMBER=1
fi
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

ARCHIVE_PATH="$BUILD_ROOT/Suite-$BUILD_NUMBER.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export-$BUILD_NUMBER"
mkdir -p "$BUILD_ROOT"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
echo ">>> archiving build $BUILD_NUMBER -> $ARCHIVE_PATH"

# 5. Archive (Release, automatic signing, cloud-managed distribution).
xcodebuild archive \
    -project "$APP_DIR/App.xcodeproj" \
    -scheme App \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    "${AUTH_ARGS[@]}" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    | tail -25
if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "ERROR: archive failed; no $ARCHIVE_PATH" >&2
    exit 1
fi
echo ">>> archive done: $ARCHIVE_PATH"

if [ "$ARCHIVE_ONLY" = "1" ]; then
    exit 0
fi

# 6. Export with destination=upload: signs for App Store Connect and uploads.
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    "${AUTH_ARGS[@]}" \
    | tail -25
echo ">>> uploaded build $BUILD_NUMBER; Apple processes it for ~5-15 min"

# 7. What to Test notes + internal group.
if [ "$NOTES" = "1" ]; then
    /usr/bin/python3 "$SCRIPT_DIR/set_testflight_notes.py" "$MARKETING_VERSION" "$BUILD_NUMBER"
fi
