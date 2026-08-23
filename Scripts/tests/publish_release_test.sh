#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
PUBLISH="$ROOT/Scripts/publish_release.sh"
[ -x "$PUBLISH" ] || { echo missing publish_release.sh >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT HUP INT TERM
git -C "$TMP" init -q -b main
git -C "$TMP" config user.email test@example.com; git -C "$TMP" config user.name Test
git -C "$TMP" remote add origin git@github.com:riyex/amp-runner.git
printf 'settings:\n  MARKETING_VERSION: "1.2.3"\n  CURRENT_PROJECT_VERSION: "41"\n' > "$TMP/project.yml"
printf 'build/\nbin/\nlog\n' > "$TMP/.gitignore"
git -C "$TMP" add . && git -C "$TMP" commit -qm release && git -C "$TMP" tag -a v1.2.3 -m release && git -C "$TMP" checkout -q --detach v1.2.3
mkdir "$TMP/build" "$TMP/bin"; printf payload > "$TMP/build/AmpRunner-1.2.3.dmg"
(cd "$TMP"; . "$ROOT/Scripts/release_common.sh"; create_release_metadata v1.2.3 build/AmpRunner-1.2.3.dmg build/AmpRunner-1.2.3.dmg.sha256 build/AmpRunner-1.2.3.provenance.json 'Developer ID Application: Example (TEAM)' TEAM)
cat > "$TMP/bin/remote-git" <<'EOF'
#!/bin/sh
printf 'git %s\n' "$*" >> "$REMOTE_LOG"
[ "$1" = ls-remote ] && printf '%b' "${REMOTE_TAGS-}"
exit 0
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$REMOTE_LOG"
case "$1 $2" in
 'repo view') printf '{"nameWithOwner":"riyex/amp-runner"}\n';;
 'release view') case "${RELEASE_STATE:-missing}" in missing) echo 'release not found' >&2; exit 1;; error) echo 'transport failure' >&2; exit 1;; esac; printf '{"isDraft":%s}\n' "$RELEASE_STATE";;
esac
EOF
cat > "$TMP/bin/codesign" <<'EOF'
#!/bin/sh
printf 'Authority=Developer ID Application: Example (TEAM)\nTeamIdentifier=TEAM\n' >&2
EOF
chmod +x "$TMP/bin/"*
export CODESIGN_COMMAND="$TMP/bin/codesign"
(cd "$TMP"; REMOTE_LOG="$TMP/log" GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3)
grep -q 'git push origin refs/tags/v1.2.3' "$TMP/log"
grep -q 'gh release create v1.2.3 .*--draft' "$TMP/log"

: > "$TMP/log"
if (cd "$TMP"; REMOTE_LOG="$TMP/log" RELEASE_STATE=error GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3) >/dev/null 2>&1; then echo ignored release API failure >&2; exit 1; fi
! grep -q 'git push' "$TMP/log"

: > "$TMP/log"; commit=$(git -C "$TMP" rev-parse HEAD)
(cd "$TMP"; REMOTE_LOG="$TMP/log" REMOTE_TAGS="$commit\trefs/tags/v1.2.3^{}\n" RELEASE_STATE=true GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3)
! grep -q 'git push' "$TMP/log"
grep -q 'gh release upload v1.2.3 .*--clobber' "$TMP/log"

: > "$TMP/log"
if (cd "$TMP"; REMOTE_LOG="$TMP/log" REMOTE_TAGS="0000000000000000000000000000000000000000\trefs/tags/v1.2.3^{}\n" GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3) >/dev/null 2>&1; then
    echo accepted conflicting remote tag >&2
    exit 1
fi
! grep -q 'gh release' "$TMP/log"

: > "$TMP/log"
if (cd "$TMP"; REMOTE_LOG="$TMP/log" REMOTE_TAGS="$commit\trefs/tags/v1.2.3^{}\n" RELEASE_STATE=false GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3) >/dev/null 2>&1; then
    echo altered published release >&2
    exit 1
fi
! grep -q 'gh release upload\|gh release create' "$TMP/log"

: > "$TMP/log"
if (cd "$TMP"; REMOTE_LOG="$TMP/log" RELEASE_STATE=false GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3) >/dev/null 2>&1; then echo published release with missing tag did not fail >&2; exit 1; fi
! grep -q 'git push' "$TMP/log"

printf changed >> "$TMP/build/AmpRunner-1.2.3.dmg"
: > "$TMP/log"
if (cd "$TMP"; REMOTE_LOG="$TMP/log" GIT_REMOTE_COMMAND="$TMP/bin/remote-git" GH_COMMAND="$TMP/bin/gh" "$PUBLISH" v1.2.3) >/dev/null 2>&1; then
    echo accepted invalid local asset >&2
    exit 1
fi
[ ! -s "$TMP/log" ]

echo "Publish release tests passed"
