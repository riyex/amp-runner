#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

git -C "$TMP" init -q -b main
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name Test
mkdir -p "$TMP/App/Resources/Assets.xcassets/AppIcon.appiconset" "$TMP/bin" "$TMP/Scripts"
cp "$ROOT/Scripts/prepare_release.sh" "$ROOT/Scripts/release_common.sh" "$TMP/Scripts/"
PREPARE="$TMP/Scripts/prepare_release.sh"
printf 'settings:\n  MARKETING_VERSION: "1.2.3"\n  CURRENT_PROJECT_VERSION: "41"\n' > "$TMP/project.yml"
printf '<plist></plist>\n' > "$TMP/App/Resources/Info.plist"
printf '{}\n' > "$TMP/App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
printf 'build/\nbin/\ncommand.log\n' > "$TMP/.gitignore"
git -C "$TMP" add .
git -C "$TMP" commit -qm release
git -C "$TMP" tag -a v1.2.3 -m release
git -C "$TMP" checkout -q --detach v1.2.3

make_command() {
    name=$1
    cat > "$TMP/bin/$name" <<'EOF'
#!/bin/sh
printf '%s\n' "$(basename "$0")" >> "$COMMAND_LOG"
EOF
    chmod +x "$TMP/bin/$name"
}

for name in tests swift plutil jq; do
    make_command "$name"
done

cat > "$TMP/bin/build" <<'EOF'
#!/bin/sh
printf 'build\n' >> "$COMMAND_LOG"
[ "$BUILD_DIR" = "$(dirname "$ARCHIVE_PATH")" ]
mkdir -p "$ARCHIVE_PATH/Products/Applications/AmpRunner.app"
EOF
cat > "$TMP/bin/package" <<'EOF'
#!/bin/sh
printf 'package\n' >> "$COMMAND_LOG"
printf payload > "$2"
EOF
cat > "$TMP/bin/notarize" <<'EOF'
#!/bin/sh
printf 'notarize\n' >> "$COMMAND_LOG"
[ "${FAIL_NOTARIZE:-0}" -eq 0 ]
EOF
cat > "$TMP/bin/sign" <<'EOF'
#!/bin/sh
printf 'sign\n' >> "$COMMAND_LOG"
[ "$CODE_SIGN_IDENTITY" = 'Developer ID Application: Example (TEAM)' ]
[ "$DEVELOPMENT_TEAM" = TEAM ]
EOF
cat > "$TMP/bin/codesign" <<'EOF'
#!/bin/sh
printf 'codesign\n' >> "$COMMAND_LOG"
printf 'Authority=Developer ID Application: Example (TEAM)\nTeamIdentifier=TEAM\n' >&2
EOF
chmod +x "$TMP/bin/build" "$TMP/bin/package" "$TMP/bin/sign" "$TMP/bin/notarize" "$TMP/bin/codesign"

run_prepare() {
    (
        cd "$TMP"
        PATH="$TMP/bin:$PATH" \
        COMMAND_LOG="$TMP/command.log" \
        BUILD_DIR="$TMP/build" \
        PROJECT_FILE="$TMP/project.yml" \
        TEST_COMMAND="$TMP/bin/tests" \
        BUILD_COMMAND="$TMP/bin/build" \
        PACKAGE_COMMAND="$TMP/bin/package" \
        SIGN_DMG_COMMAND="$TMP/bin/sign" \
        NOTARIZE_COMMAND="$TMP/bin/notarize" \
        CODESIGN_COMMAND="$TMP/bin/codesign" \
        DEVELOPMENT_TEAM=TEAM \
        FAIL_NOTARIZE="${FAIL_NOTARIZE:-0}" \
        "$PREPARE" v1.2.3
    )
}

run_prepare >/dev/null
[ "$(tr '\n' ' ' < "$TMP/command.log")" = "tests swift plutil jq build codesign package sign notarize codesign " ]
[ -f "$TMP/build/AmpRunner-1.2.3.dmg" ]
[ -f "$TMP/build/AmpRunner-1.2.3.dmg.sha256" ]
[ -f "$TMP/build/AmpRunner-1.2.3.provenance.json" ]

: > "$TMP/command.log"
FAIL_NOTARIZE=1
export FAIL_NOTARIZE
if run_prepare >/dev/null 2>&1; then
    echo "continued after notarization failure" >&2
    exit 1
fi
[ "$(tr '\n' ' ' < "$TMP/command.log")" = "tests swift plutil jq build codesign package sign notarize " ]
[ ! -e "$TMP/build/AmpRunner-1.2.3.dmg.sha256" ]
[ ! -e "$TMP/build/AmpRunner-1.2.3.provenance.json" ]

echo "Prepare release tests passed"
