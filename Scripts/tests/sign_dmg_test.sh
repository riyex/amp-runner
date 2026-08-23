#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT HUP INT TERM
printf dmg > "$TMP/release.dmg"
cat > "$TMP/codesign" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$COMMAND_LOG"
case " $* " in *' -dv '*) printf 'Authority=Developer ID Application: Example (TEAM)\nTeamIdentifier=TEAM\n' >&2;; esac
EOF
chmod +x "$TMP/codesign"
COMMAND_LOG="$TMP/log" CODESIGN_COMMAND="$TMP/codesign" CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAM)' DEVELOPMENT_TEAM=TEAM "$ROOT/Scripts/sign_dmg.sh" "$TMP/release.dmg"
grep -q -- '--force --sign Developer ID Application: Example (TEAM) --timestamp .*release.dmg' "$TMP/log"
grep -q -- '--verify --strict --verbose=2 .*release.dmg' "$TMP/log"
if COMMAND_LOG="$TMP/log" CODESIGN_COMMAND="$TMP/codesign" CODE_SIGN_IDENTITY='Apple Development: Example (TEAM)' DEVELOPMENT_TEAM=TEAM "$ROOT/Scripts/sign_dmg.sh" "$TMP/release.dmg" >/dev/null 2>&1; then echo accepted wrong identity >&2; exit 1; fi
echo "DMG signing tests passed"
