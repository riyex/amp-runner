#!/bin/sh
# Archives and verifies the Developer ID application.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

ARCHIVE_PATH="${ARCHIVE_PATH:-$PWD/build/AmpRunner.xcarchive}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
PROJECT_FILE="${PROJECT_FILE:-project.yml}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
GENERATE_PROJECT_COMMAND="${GENERATE_PROJECT_COMMAND:-$ROOT/Scripts/generate_project.sh}"
XCODEBUILD_COMMAND="${XCODEBUILD_COMMAND:-xcodebuild}"
CODESIGN_COMMAND="${CODESIGN_COMMAND:-codesign}"
PLUTIL_COMMAND="${PLUTIL_COMMAND:-plutil}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID.}"
command -v python3 >/dev/null 2>&1 || { echo "python3 is required to inspect entitlements" >&2; exit 1; }

MARKETING_VERSION=$(awk '$1 == "MARKETING_VERSION:" { gsub(/^"|"$/, "", $2); print $2; count++ } END { if (count != 1) exit 1 }' "$PROJECT_FILE") || { echo "MARKETING_VERSION must occur exactly once" >&2; exit 1; }
BUILD_NUMBER=$(awk '$1 == "CURRENT_PROJECT_VERSION:" { gsub(/^"|"$/, "", $2); print $2; count++ } END { if (count != 1) exit 1 }' "$PROJECT_FILE") || { echo "CURRENT_PROJECT_VERSION must occur exactly once" >&2; exit 1; }
case "$BUILD_NUMBER" in ''|*[!0-9]*) echo "CURRENT_PROJECT_VERSION must be a non-negative integer" >&2; exit 1;; esac
echo "Building release $MARKETING_VERSION ($BUILD_NUMBER)"

"$GENERATE_PROJECT_COMMAND"

archive_parent=$(CDPATH= cd -- "$(dirname "$ARCHIVE_PATH")" 2>/dev/null && pwd -P) || { echo "ARCHIVE_PATH parent does not exist" >&2; exit 1; }
build_dir_canonical=$(CDPATH= cd -- "$BUILD_DIR" 2>/dev/null && pwd -P) || { echo "BUILD_DIR does not exist" >&2; exit 1; }
[ "$archive_parent" = "$build_dir_canonical" ] || { echo "ARCHIVE_PATH must be directly under BUILD_DIR" >&2; exit 1; }
case "$(basename "$ARCHIVE_PATH")" in *.xcarchive) :;; *) echo "ARCHIVE_PATH must have a .xcarchive suffix" >&2; exit 1;; esac
rm -rf "$ARCHIVE_PATH"

"$XCODEBUILD_COMMAND" \
    -project AmpRunner.xcodeproj \
    -scheme AmpRunner \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

APP="$ARCHIVE_PATH/Products/Applications/AmpRunner.app"
HELPER="$APP/Contents/Helpers/AmpRunnerMonitor"
INFO_PLIST="$APP/Contents/Info.plist"

archive_marketing=$("$PLUTIL_COMMAND" -extract CFBundleShortVersionString raw -o - "$INFO_PLIST") || { echo "Could not inspect archived marketing version" >&2; exit 1; }
archive_build=$("$PLUTIL_COMMAND" -extract CFBundleVersion raw -o - "$INFO_PLIST") || { echo "Could not inspect archived build number" >&2; exit 1; }
[ "$archive_marketing" = "$MARKETING_VERSION" ] || { echo "Archived CFBundleShortVersionString does not match project.yml" >&2; exit 1; }
[ "$archive_build" = "$BUILD_NUMBER" ] || { echo "Archived CFBundleVersion does not match project.yml" >&2; exit 1; }

archive_authority=
for executable in "$HELPER" "$APP"; do
    "$CODESIGN_COMMAND" --verify --strict --verbose=2 "$executable"
    signature=$("$CODESIGN_COMMAND" -dv --verbose=4 "$executable" 2>&1) || { echo "Could not inspect signature: $executable" >&2; exit 1; }
    executable_authority=$(printf '%s\n' "$signature" | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)
    if [ -z "$executable_authority" ]; then
        echo "Archive is not signed with a Developer ID Application identity: $executable" >&2
        exit 1
    fi
    if [ -z "$archive_authority" ]; then
        archive_authority=$executable_authority
    elif [ "$executable_authority" != "$archive_authority" ]; then
        echo "App and helper use different Developer ID Application identities" >&2
        exit 1
    fi
    case "$CODE_SIGN_IDENTITY" in
        'Developer ID Application:'*)
            [ "$executable_authority" = "$CODE_SIGN_IDENTITY" ] || { echo "Archive authority does not match CODE_SIGN_IDENTITY: $executable" >&2; exit 1; }
            ;;
    esac
    printf '%s\n' "$signature" | grep -q "^TeamIdentifier=$DEVELOPMENT_TEAM$" || { echo "Archive TeamIdentifier does not match DEVELOPMENT_TEAM: $executable" >&2; exit 1; }
    printf '%s\n' "$signature" | grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' || { echo "Archive does not use Hardened Runtime: $executable" >&2; exit 1; }

    entitlements_raw=$(mktemp)
    if ! "$CODESIGN_COMMAND" -d --entitlements :- "$executable" >"$entitlements_raw" 2>/dev/null; then
        rm -f "$entitlements_raw"
        echo "Could not inspect entitlements: $executable" >&2; exit 1
    fi
    if [ -s "$entitlements_raw" ]; then
        if python3 - "$entitlements_raw" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
value = entitlements.get("com.apple.security.get-task-allow")
if value is True:
    raise SystemExit(2)
if value is not None and value is not False:
    raise SystemExit(3)
PY
        then
            :
        else
            status=$?
            rm -f "$entitlements_raw"
            case "$status" in
                2) echo "Archive contains the development-only get-task-allow entitlement: $executable" >&2;;
                *) echo "Could not parse entitlements: $executable" >&2;;
            esac
            exit 1
        fi
    fi
    rm -f "$entitlements_raw"
done

echo "Archived AmpRunner to $ARCHIVE_PATH"
