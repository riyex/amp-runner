#!/bin/sh
set -eu
[ "$#" -eq 2 ] || { echo "Usage: $0 APP DMG" >&2; exit 2; }
APP=$1 DMG=$2
[ -d "$APP" ] || { echo "Application does not exist: $APP" >&2; exit 1; }
BUILD_DIR=${BUILD_DIR:-$(dirname "$DMG")}
DITTO_COMMAND=${DITTO_COMMAND:-ditto}
HDIUTIL_COMMAND=${HDIUTIL_COMMAND:-hdiutil}
mkdir -p "$BUILD_DIR" "$(dirname "$DMG")"
STAGE=$(mktemp -d "$BUILD_DIR/dmg-stage.XXXXXX")
RW="$BUILD_DIR/.AmpRunner-rw.$$.dmg"
COMPRESSED="$BUILD_DIR/.AmpRunner-compressed.$$.dmg"
cleanup() { rm -rf "$STAGE"; rm -f "$RW" "$COMPRESSED"; }
trap cleanup EXIT HUP INT TERM
"$DITTO_COMMAND" "$APP" "$STAGE/AmpRunner.app"
ln -s /Applications "$STAGE/Applications"
"$HDIUTIL_COMMAND" create -quiet -fs HFS+ -volname AmpRunner -srcfolder "$STAGE" "$RW"
"$HDIUTIL_COMMAND" convert -quiet "$RW" -format UDZO -o "$COMPRESSED"
mv -f "$COMPRESSED" "$DMG"
echo "Packaged $DMG"
