#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin"
ARCHIVE="$TMP/AmpRunner.xcarchive"
mkdir -p "$ARCHIVE/Products/Applications/AmpRunner.app/Contents/Helpers"
cat > "$ARCHIVE/Products/Applications/AmpRunner.app/Contents/Info.plist" <<'EOF'
<plist><dict><key>CFBundleShortVersionString</key><string>1.2.3</string><key>CFBundleVersion</key><string>41</string></dict></plist>
EOF
cat > "$TMP/project.yml" <<'EOF'
settings:
  MARKETING_VERSION: "1.2.3"
  CURRENT_PROJECT_VERSION: "41"
EOF
cat > "$TMP/bin/generate" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/xcodebuild" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$COMMAND_LOG"
mkdir -p "$ARCHIVE_PATH/Products/Applications/AmpRunner.app/Contents/Helpers"
printf '<plist><dict><key>CFBundleShortVersionString</key><string>%s</string><key>CFBundleVersion</key><string>41</string></dict></plist>\n' "${ARCHIVE_VERSION:-1.2.3}" > "$ARCHIVE_PATH/Products/Applications/AmpRunner.app/Contents/Info.plist"
EOF
cat > "$TMP/bin/codesign" <<'EOF'
#!/bin/sh
case " $* " in
 *' -dv '*) authority=${MOCK_AUTHORITY:-Developer ID Application: Example (TEAM)}; case "$*" in *Contents/Helpers/*) authority=${HELPER_AUTHORITY:-$authority};; esac; printf 'Authority=%s\nTeamIdentifier=%s\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\n' "$authority" "${MOCK_TEAM:-TEAM}" >&2;;
 *' -d '*--entitlements*) [ "${ENTITLEMENTS_FAIL:-0}" -eq 0 ] || exit 1; [ -z "${MOCK_ENTITLEMENTS+x}" ] || { printf '%s' "$MOCK_ENTITLEMENTS"; exit; }; printf '%s\n' '<plist><dict></dict></plist>';;
esac
EOF
cat > "$TMP/bin/plutil" <<'EOF'
#!/bin/sh
case "$1" in
 -extract) key=$2; file=$6; sed -n "s:.*<key>$key</key><string>\([^<]*\)</string>.*:\1:p" "$file"; grep -q "<key>$key</key><true/>" "$file" && printf true; grep -q "<key>$key</key><false/>" "$file" && printf false; exit 0;;
 -convert) [ "${PLUTIL_FAIL:-0}" -eq 0 ] && [ -s "$5" ] || exit 1; cp "$5" "$4";;
esac
EOF
chmod +x "$TMP/bin/"*
CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAM)'
export CODE_SIGN_IDENTITY
before=$(shasum "$TMP/project.yml")
COMMAND_LOG="$TMP/log" PROJECT_FILE="$TMP/project.yml" ARCHIVE_PATH="$ARCHIVE" BUILD_DIR="$TMP" \
GENERATE_PROJECT_COMMAND="$TMP/bin/generate" XCODEBUILD_COMMAND="$TMP/bin/xcodebuild" CODESIGN_COMMAND="$TMP/bin/codesign" PLUTIL_COMMAND="$TMP/bin/plutil" DEVELOPMENT_TEAM=TEAM \
    "$ROOT/Scripts/build_developer_id.sh"
[ "$before" = "$(shasum "$TMP/project.yml")" ]
grep -q 'CURRENT_PROJECT_VERSION=41' "$TMP/log"

sed 's/"41"/"bad"/' "$TMP/project.yml" > "$TMP/invalid.yml"
: > "$TMP/log"
if COMMAND_LOG="$TMP/log" PROJECT_FILE="$TMP/invalid.yml" ARCHIVE_PATH="$ARCHIVE" BUILD_DIR="$TMP" GENERATE_PROJECT_COMMAND="$TMP/bin/generate" XCODEBUILD_COMMAND="$TMP/bin/xcodebuild" CODESIGN_COMMAND="$TMP/bin/codesign" DEVELOPMENT_TEAM=TEAM "$ROOT/Scripts/build_developer_id.sh" >/dev/null 2>&1; then
    echo accepted invalid build >&2; exit 1
fi
[ ! -s "$TMP/log" ]

run_reject() {
    if COMMAND_LOG="$TMP/log" PROJECT_FILE="$TMP/project.yml" ARCHIVE_PATH="$ARCHIVE" BUILD_DIR="$TMP" GENERATE_PROJECT_COMMAND="$TMP/bin/generate" XCODEBUILD_COMMAND="$TMP/bin/xcodebuild" CODESIGN_COMMAND="$TMP/bin/codesign" PLUTIL_COMMAND="$TMP/bin/plutil" DEVELOPMENT_TEAM=TEAM "$@" "$ROOT/Scripts/build_developer_id.sh" >/dev/null 2>&1; then
        echo "accepted invalid archive: $*" >&2; exit 1
    fi
}

MOCK_TEAM=OTHER run_reject
unset MOCK_TEAM
MOCK_AUTHORITY='Apple Development: Example (TEAM)' run_reject
unset MOCK_AUTHORITY
HELPER_AUTHORITY='Developer ID Application: Other (TEAM)' run_reject
unset HELPER_AUTHORITY
MOCK_ENTITLEMENTS='<plist><dict><key>com.apple.security.get-task-allow</key><false/></dict></plist>' COMMAND_LOG="$TMP/log" PROJECT_FILE="$TMP/project.yml" ARCHIVE_PATH="$ARCHIVE" BUILD_DIR="$TMP" GENERATE_PROJECT_COMMAND="$TMP/bin/generate" XCODEBUILD_COMMAND="$TMP/bin/xcodebuild" CODESIGN_COMMAND="$TMP/bin/codesign" PLUTIL_COMMAND="$TMP/bin/plutil" DEVELOPMENT_TEAM=TEAM "$ROOT/Scripts/build_developer_id.sh" >/dev/null
unset MOCK_ENTITLEMENTS
MOCK_ENTITLEMENTS='' COMMAND_LOG="$TMP/log" PROJECT_FILE="$TMP/project.yml" ARCHIVE_PATH="$ARCHIVE" BUILD_DIR="$TMP" GENERATE_PROJECT_COMMAND="$TMP/bin/generate" XCODEBUILD_COMMAND="$TMP/bin/xcodebuild" CODESIGN_COMMAND="$TMP/bin/codesign" PLUTIL_COMMAND="$TMP/bin/plutil" DEVELOPMENT_TEAM=TEAM "$ROOT/Scripts/build_developer_id.sh" >/dev/null
unset MOCK_ENTITLEMENTS
MOCK_ENTITLEMENTS='<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>' run_reject
unset MOCK_ENTITLEMENTS
MOCK_ENTITLEMENTS='not a plist' run_reject
unset MOCK_ENTITLEMENTS
ENTITLEMENTS_FAIL=1 run_reject
unset ENTITLEMENTS_FAIL

ARCHIVE_VERSION=9.9.9 run_reject
unset ARCHIVE_VERSION

rm -rf "$ARCHIVE"
mkdir -p "$ARCHIVE"; : > "$ARCHIVE/stale-sentinel"
COMMAND_LOG="$TMP/log" PROJECT_FILE="$TMP/project.yml" ARCHIVE_PATH="$ARCHIVE" BUILD_DIR="$TMP" GENERATE_PROJECT_COMMAND="$TMP/bin/generate" XCODEBUILD_COMMAND="$TMP/bin/xcodebuild" CODESIGN_COMMAND="$TMP/bin/codesign" PLUTIL_COMMAND="$TMP/bin/plutil" DEVELOPMENT_TEAM=TEAM "$ROOT/Scripts/build_developer_id.sh" >/dev/null 2>&1 || true
[ ! -e "$ARCHIVE/stale-sentinel" ] || { echo stale archive survived >&2; exit 1; }
echo "Developer ID build tests passed"
