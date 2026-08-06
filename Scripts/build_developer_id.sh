#!/bin/sh
# Archives the primary (Developer ID / direct distribution) target.
# Signing, notarization, and packaging are separate manual steps — see ARCHITECTURE.md.
set -eu

cd "$(dirname "$0")/.."

./Scripts/generate_project.sh

ARCHIVE_PATH="${ARCHIVE_PATH:-$PWD/build/AmpRunner.xcarchive}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID.}"

xcodebuild \
    -project AmpRunner.xcodeproj \
    -scheme AmpRunner \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    archive

APP="$ARCHIVE_PATH/Products/Applications/AmpRunner.app"
HELPER="$APP/Contents/Helpers/AmpRunnerMonitor"

for executable in "$HELPER" "$APP"; do
    codesign --verify --strict --verbose=2 "$executable"
    if ! codesign -dv --verbose=4 "$executable" 2>&1 \
        | grep -q '^Authority=Developer ID Application:'; then
        echo "Archive is not signed with a Developer ID Application identity: $executable" >&2
        exit 1
    fi
done

echo "Archived AmpRunner to $ARCHIVE_PATH"
