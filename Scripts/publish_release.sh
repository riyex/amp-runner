#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "Usage: $0 vX.Y.Z" >&2; exit 2; }
TAG=$1
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/Scripts/release_common.sh"
BUILD_DIR=${BUILD_DIR:-build}
PROJECT_FILE=${PROJECT_FILE:-project.yml}
GH_COMMAND=${GH_COMMAND:-gh}
GIT_REMOTE_COMMAND=${GIT_REMOTE_COMMAND:-git}

identity=$(validate_release_checkout "$TAG" "$PROJECT_FILE")
commit=$(printf '%s\n' "$identity" | awk -F '\t' '{print $3}')
paths=$(release_artifact_paths "$TAG" "$BUILD_DIR")
DMG=$(printf '%s\n' "$paths" | sed -n '1p')
CHECKSUM=$(printf '%s\n' "$paths" | sed -n '2p')
PROVENANCE=$(printf '%s\n' "$paths" | sed -n '3p')
validate_release_assets "$TAG" "$DMG" "$CHECKSUM" "$PROVENANCE" "$PROJECT_FILE"
command -v "$GH_COMMAND" >/dev/null 2>&1 || { echo "gh is required" >&2; exit 1; }
command -v "$GIT_REMOTE_COMMAND" >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
"$GH_COMMAND" auth status >/dev/null
repository=$("$GH_COMMAND" repo view --json nameWithOwner | python3 -c 'import json,sys; print(json.load(sys.stdin)["nameWithOwner"])')
origin=$(git remote get-url origin)
case "$origin" in
    git@github.com:*) origin_repo=${origin#git@github.com:};;
    ssh://git@github.com/*) origin_repo=${origin#ssh://git@github.com/};;
    https://github.com/*) origin_repo=${origin#https://github.com/};;
    http://github.com/*) origin_repo=${origin#http://github.com/};;
    *) echo "origin is not a GitHub repository: $origin" >&2; exit 1;;
esac
origin_repo=${origin_repo%.git}
[ "$origin_repo" = "$repository" ] || { echo "origin ($origin_repo) does not match GitHub repository ($repository)" >&2; exit 1; }

release_error_file=$(mktemp)
trap 'rm -f "$release_error_file"' EXIT HUP INT TERM
if release_json=$("$GH_COMMAND" release view "$TAG" --json isDraft 2>"$release_error_file"); then
    is_draft=$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["isDraft"]).lower())')
    [ "$is_draft" = true ] || { echo "Release $TAG is already published" >&2; exit 1; }
    release_state=draft
elif [ "$(cat "$release_error_file")" = "release not found" ]; then
    release_state=missing
else
    cat "$release_error_file" >&2
    exit 1
fi

remote=$("$GIT_REMOTE_COMMAND" ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")
if [ -z "$remote" ]; then
    "$GIT_REMOTE_COMMAND" push origin "refs/tags/$TAG"
else
    remote_commit=$(printf '%s\n' "$remote" | awk -v ref="refs/tags/$TAG^{}" '$2 == ref {print $1}')
    [ "$remote_commit" = "$commit" ] || { echo "Remote tag $TAG conflicts with the local release" >&2; exit 1; }
fi

if [ "$release_state" = draft ]; then
    "$GH_COMMAND" release upload "$TAG" "$DMG" "$CHECKSUM" "$PROVENANCE" --clobber
else
    "$GH_COMMAND" release create "$TAG" "$DMG" "$CHECKSUM" "$PROVENANCE" --draft --generate-notes --title "$TAG"
fi
echo "Draft release ready: $TAG"
