#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "Usage: $0 vX.Y.Z" >&2; exit 2; }
TAG=$1
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/Scripts/release_common.sh"
BUILD_DIR=${BUILD_DIR:-$ROOT/build}
ARCHIVE_PATH=${ARCHIVE_PATH:-$BUILD_DIR/AmpRunner.xcarchive}
PROJECT_FILE=${PROJECT_FILE:-project.yml}
TEST_COMMAND=${TEST_COMMAND:-$ROOT/Scripts/tests/run_release_tool_tests.sh}
BUILD_COMMAND=${BUILD_COMMAND:-$ROOT/Scripts/build_developer_id.sh}
PACKAGE_COMMAND=${PACKAGE_COMMAND:-$ROOT/Scripts/package_dmg.sh}
SIGN_DMG_COMMAND=${SIGN_DMG_COMMAND:-$ROOT/Scripts/sign_dmg.sh}
NOTARIZE_COMMAND=${NOTARIZE_COMMAND:-$ROOT/Scripts/notarize_dmg.sh}
CODESIGN_COMMAND=${CODESIGN_COMMAND:-codesign}
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID.}"
for command_name in git swift plutil jq python3 shasum "$TEST_COMMAND" "$BUILD_COMMAND" "$PACKAGE_COMMAND" "$SIGN_DMG_COMMAND" "$NOTARIZE_COMMAND" "$CODESIGN_COMMAND"; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "Required command not found: $command_name" >&2; exit 1; }
done
validate_release_checkout "$TAG" "$PROJECT_FILE" >/dev/null
paths=$(release_artifact_paths "$TAG" "$BUILD_DIR")
DMG=$(printf '%s\n' "$paths" | sed -n '1p')
CHECKSUM=$(printf '%s\n' "$paths" | sed -n '2p')
PROVENANCE=$(printf '%s\n' "$paths" | sed -n '3p')
mkdir -p "$BUILD_DIR"
rm -f "$DMG" "$CHECKSUM" "$PROVENANCE"
"$TEST_COMMAND"
swift test
plutil -lint App/Resources/Info.plist
find App/Resources/Assets.xcassets -name Contents.json -exec jq empty '{}' ';'
PROJECT_FILE="$PROJECT_FILE" BUILD_DIR="$BUILD_DIR" ARCHIVE_PATH="$ARCHIVE_PATH" "$BUILD_COMMAND"
APP="$ARCHIVE_PATH/Products/Applications/AmpRunner.app"
SIGNED_BY=$("$CODESIGN_COMMAND" -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)
[ -n "$SIGNED_BY" ] || { echo "Could not determine Developer ID authority" >&2; exit 1; }
"$PACKAGE_COMMAND" "$APP" "$DMG"
CODE_SIGN_IDENTITY="$SIGNED_BY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" "$SIGN_DMG_COMMAND" "$DMG"
"$NOTARIZE_COMMAND" "$DMG"
create_release_metadata "$TAG" "$DMG" "$CHECKSUM" "$PROVENANCE" "$SIGNED_BY" "$DEVELOPMENT_TEAM" "$PROJECT_FILE"
validate_release_assets "$TAG" "$DMG" "$CHECKSUM" "$PROVENANCE" "$PROJECT_FILE"
printf '%s\n' "$DMG" "$CHECKSUM" "$PROVENANCE"
