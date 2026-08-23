#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "Usage: $0 DMG" >&2; exit 2; }
DMG=$1
[ -f "$DMG" ] || { echo "DMG does not exist: $DMG" >&2; exit 1; }
NOTARY_PROFILE=${NOTARY_PROFILE:-AmpRunner Notary}
XCRUN_COMMAND=${XCRUN_COMMAND:-xcrun}
SPCTL_COMMAND=${SPCTL_COMMAND:-spctl}
"$XCRUN_COMMAND" notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
"$XCRUN_COMMAND" stapler staple "$DMG"
"$XCRUN_COMMAND" stapler validate "$DMG"
"$SPCTL_COMMAND" --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Notarized $DMG"
