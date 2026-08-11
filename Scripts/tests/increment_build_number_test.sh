#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
INCREMENTER="$ROOT/Scripts/increment_build_number.sh"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM

cat > "$TMPDIR_ROOT/project.yml" <<'EOF'
settings:
  MARKETING_VERSION: "1.0.0"
  CURRENT_PROJECT_VERSION: "41"
EOF
chmod 640 "$TMPDIR_ROOT/project.yml"

actual=$("$INCREMENTER" "$TMPDIR_ROOT/project.yml")
[ "$actual" = "42" ]
grep -q 'CURRENT_PROJECT_VERSION: "42"' "$TMPDIR_ROOT/project.yml"
[ "$(stat -f '%Lp' "$TMPDIR_ROOT/project.yml")" = "640" ]

index=0
while [ "$index" -lt 10 ]; do
    "$INCREMENTER" "$TMPDIR_ROOT/project.yml" >/dev/null &
    index=$((index + 1))
done
wait
[ "$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2 }' "$TMPDIR_ROOT/project.yml")" = "52" ]

cat > "$TMPDIR_ROOT/invalid.yml" <<'EOF'
settings:
  CURRENT_PROJECT_VERSION: "release"
EOF

if "$INCREMENTER" "$TMPDIR_ROOT/invalid.yml" >/dev/null 2>&1; then
    echo "accepted a non-numeric build number" >&2
    exit 1
fi

echo "Build number increment tests passed"
