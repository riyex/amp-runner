#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
VALIDATOR="$ROOT/Scripts/validate_release_branch.sh"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM

cp "$ROOT/project.yml" "$TMPDIR_ROOT/project.yml"

actual=$("$VALIDATOR" release/1.0.0 "$TMPDIR_ROOT/project.yml")
[ "$actual" = "1.0.0" ]

if "$VALIDATOR" feature/example "$TMPDIR_ROOT/project.yml" >/dev/null 2>&1; then
    echo "accepted a non-release branch" >&2
    exit 1
fi

if "$VALIDATOR" release/1.0 "$TMPDIR_ROOT/project.yml" >/dev/null 2>&1; then
    echo "accepted an invalid semantic version" >&2
    exit 1
fi

sed 's/MARKETING_VERSION: "1.0.0"/MARKETING_VERSION: "01.0.0"/' \
    "$ROOT/project.yml" > "$TMPDIR_ROOT/leading-zero.yml"
if "$VALIDATOR" release/01.0.0 "$TMPDIR_ROOT/leading-zero.yml" >/dev/null 2>&1; then
    echo "accepted a version with a leading zero" >&2
    exit 1
fi

if "$VALIDATOR" release/1.0.0/hotfix "$TMPDIR_ROOT/project.yml" >/dev/null 2>&1; then
    echo "accepted a nested release branch" >&2
    exit 1
fi

if "$VALIDATOR" release/9.9.9 "$TMPDIR_ROOT/project.yml" >/dev/null 2>&1; then
    echo "accepted a version that does not match project.yml" >&2
    exit 1
fi

sed '/MARKETING_VERSION:/d' "$ROOT/project.yml" > "$TMPDIR_ROOT/missing.yml"
if "$VALIDATOR" release/1.0.0 "$TMPDIR_ROOT/missing.yml" >/dev/null 2>&1; then
    echo "accepted a project without MARKETING_VERSION" >&2
    exit 1
fi

echo "Release branch validation tests passed"
