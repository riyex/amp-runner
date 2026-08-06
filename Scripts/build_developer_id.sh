#!/bin/sh
# Archives the primary (Developer ID / direct distribution) target.
# Signing, notarization, and packaging are separate manual steps — see ARCHITECTURE.md.
set -eu

cd "$(dirname "$0")/.."

./Scripts/generate_project.sh

ARCHIVE_PATH="${ARCHIVE_PATH:-$PWD/build/AmpRunner.xcarchive}"

xcodebuild \
    -project AmpRunner.xcodeproj \
    -scheme AmpRunner \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive

echo "Archived AmpRunner to $ARCHIVE_PATH"
