#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "Usage: $0 DMG" >&2; exit 2; }
DMG=$1
[ -f "$DMG" ] || { echo "DMG does not exist: $DMG" >&2; exit 1; }
CODESIGN_COMMAND=${CODESIGN_COMMAND:-codesign}
: "${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to the exact Developer ID Application identity.}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID.}"
case "$CODE_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) echo "CODE_SIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 1;; esac
"$CODESIGN_COMMAND" --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG"
"$CODESIGN_COMMAND" --verify --strict --verbose=2 "$DMG"
details=$("$CODESIGN_COMMAND" -dv --verbose=4 "$DMG" 2>&1) || { echo "Could not inspect DMG signature" >&2; exit 1; }
printf '%s\n' "$details" | grep -Fx "Authority=$CODE_SIGN_IDENTITY" >/dev/null || { echo "DMG authority does not match CODE_SIGN_IDENTITY" >&2; exit 1; }
printf '%s\n' "$details" | grep -Fx "TeamIdentifier=$DEVELOPMENT_TEAM" >/dev/null || { echo "DMG TeamIdentifier does not match DEVELOPMENT_TEAM" >&2; exit 1; }
echo "Signed $DMG"
