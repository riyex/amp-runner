#!/bin/sh
set -eu

PROJECT_FILE="${1:-project.yml}"
LOCK_DIR="${PROJECT_FILE}.build-number.lock"
TEMP_FILE=

cleanup() {
    [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
    rm -rf "$LOCK_DIR"
}

ATTEMPTS=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 300 ]; then
        echo "Timed out waiting for the build number lock: $LOCK_DIR" >&2
        exit 1
    fi
    sleep 0.1
done

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' \
    "$PROJECT_FILE" > "$LOCK_DIR/current"
IFS= read -r CURRENT_BUILD < "$LOCK_DIR/current" || CURRENT_BUILD=

case "$CURRENT_BUILD" in
    ''|*[!0-9]*)
        echo "CURRENT_PROJECT_VERSION must be a non-negative integer in $PROJECT_FILE" >&2
        exit 1
        ;;
esac

NEXT_BUILD=$((CURRENT_BUILD + 1))
TEMP_FILE="${PROJECT_FILE}.$$"
(umask 077 && : > "$TEMP_FILE")

sed "s/^\([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\)\"$CURRENT_BUILD\"/\1\"$NEXT_BUILD\"/" \
    "$PROJECT_FILE" > "$TEMP_FILE"
stat -f '%Lp' "$PROJECT_FILE" > "$LOCK_DIR/mode"
IFS= read -r PROJECT_MODE < "$LOCK_DIR/mode"
chmod "$PROJECT_MODE" "$TEMP_FILE"
mv "$TEMP_FILE" "$PROJECT_FILE"
TEMP_FILE=

echo "$NEXT_BUILD"
