#!/bin/sh
set -eu

BRANCH_NAME=${1:-${GITHUB_REF_NAME:-}}
PROJECT_FILE=${2:-project.yml}

case "$BRANCH_NAME" in
    release/*) VERSION=${BRANCH_NAME#release/} ;;
    *)
        echo "Release branch must be named release/X.Y.Z; got: $BRANCH_NAME" >&2
        exit 1
        ;;
esac

NUMBER='(0|[1-9][0-9]*)'
if ! printf '%s\n' "$VERSION" | grep -Eq "^${NUMBER}\.${NUMBER}\.${NUMBER}$"; then
    echo "Release version must use X.Y.Z; got: $VERSION" >&2
    exit 1
fi

MARKETING_VERSION=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_FILE")
if [ -z "$MARKETING_VERSION" ]; then
    echo "MARKETING_VERSION is missing from $PROJECT_FILE" >&2
    exit 1
fi

if [ "$VERSION" != "$MARKETING_VERSION" ]; then
    echo "Branch version $VERSION does not match MARKETING_VERSION $MARKETING_VERSION" >&2
    exit 1
fi

printf '%s\n' "$VERSION"
