#!/bin/sh

release_error() { echo "$*" >&2; return 1; }

release_project_value() {
    key=$1 file=$2
    awk -v key="$key" '$1 == key ":" { gsub(/^"|"$/, "", $2); print $2; found++ } END { if (found != 1) exit 1 }' "$file"
}

validate_release_checkout() {
    tag=${1-} project_file=${2:-project.yml}
    case "$tag" in
        v*) version=${tag#v};
            printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || release_error "Tag must be vX.Y.Z: $tag" || return 1 ;;
        *) release_error "Tag must be vX.Y.Z: $tag" || return 1 ;;
    esac
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || release_error "Not in a Git checkout" || return 1
    if git symbolic-ref -q HEAD >/dev/null 2>&1; then release_error "Release checkout must be detached"; return 1; fi
    [ "$(git cat-file -t "$tag" 2>/dev/null)" = tag ] || release_error "Release tag must be annotated: $tag" || return 1
    commit=$(git rev-parse HEAD)
    [ "$(git rev-parse "$tag^{commit}")" = "$commit" ] || release_error "HEAD is not the release tag $tag" || return 1
    [ -z "$(git status --porcelain --untracked-files=all)" ] || release_error "Release checkout is not clean" || return 1
    marketing=$(release_project_value MARKETING_VERSION "$project_file") || release_error "MARKETING_VERSION must occur exactly once" || return 1
    build=$(release_project_value CURRENT_PROJECT_VERSION "$project_file") || release_error "CURRENT_PROJECT_VERSION must occur exactly once" || return 1
    [ "$marketing" = "$version" ] || release_error "Tag version $version does not match MARKETING_VERSION $marketing" || return 1
    case "$build" in ''|*[!0-9]*) release_error "CURRENT_PROJECT_VERSION must be a non-negative integer" || return 1;; esac
    printf '%s\t%s\t%s\n' "$version" "$build" "$commit"
}

release_artifact_paths() {
    tag=$1 build_dir=${2:-build}
    version=${tag#v}
    printf '%s\n' "$build_dir/AmpRunner-$version.dmg" "$build_dir/AmpRunner-$version.dmg.sha256" "$build_dir/AmpRunner-$version.provenance.json"
}

create_release_metadata() {
    tag=$1 dmg=$2 checksum=$3 provenance=$4 signed_by=$5 signing_team=$6 project_file=${7:-project.yml}
    case "$signed_by" in 'Developer ID Application:'*) :;; *) release_error "Signer must be a Developer ID Application authority" || return 1;; esac
    [ -n "$signing_team" ] || release_error "Signer team must not be empty" || return 1
    identity=$(validate_release_checkout "$tag" "$project_file") || return 1
    old_ifs=$IFS; IFS=' '; IFS=$(printf '\t'); set -- $identity; IFS=$old_ifs
    version=$1 build=$2 commit=$3
    digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
    artifact=$(basename "$dmg")
    printf '%s  %s\n' "$digest" "$artifact" > "$checksum.tmp"
    mv "$checksum.tmp" "$checksum"
    python3 - "$provenance.tmp" "$version" "$build" "$tag" "$commit" "$artifact" "$digest" "$signed_by" "$signing_team" <<'PY'
import json, sys
path, version, build, tag, commit, artifact, digest, authority, team = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"product":"AmpRunner", "marketing_version":version,
               "build_number":int(build), "tag":tag, "commit":commit,
               "artifact":artifact, "sha256":digest,
               "developer_id_authority":authority,
               "developer_team":team,
               "notarized":True}, f,
              indent=2, sort_keys=True)
    f.write("\n")
PY
    mv "$provenance.tmp" "$provenance"
}

validate_release_assets() {
    tag=$1 dmg=$2 checksum=$3 provenance=$4 project_file=${5:-project.yml}
    [ -f "$dmg" ] && [ -f "$checksum" ] && [ -f "$provenance" ] || release_error "Release assets are missing" || return 1
    identity=$(validate_release_checkout "$tag" "$project_file") || return 1
    old_ifs=$IFS; IFS=$(printf '\t'); set -- $identity; IFS=$old_ifs
    version=$1 build=$2 commit=$3 artifact=$(basename "$dmg")
    digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
    [ "$(cat "$checksum")" = "$digest  $artifact" ] || release_error "DMG checksum does not match" || return 1
    codesign_command=${CODESIGN_COMMAND:-codesign}
    signer=$("$codesign_command" -dv --verbose=4 "$dmg" 2>&1) || release_error "Could not inspect DMG signature" || return 1
    signer_authority=$(printf '%s\n' "$signer" | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)
    signer_team=$(printf '%s\n' "$signer" | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' | head -n 1)
    [ -n "$signer_authority" ] && [ -n "$signer_team" ] || release_error "DMG does not have a Developer ID Application signature" || return 1
    python3 - "$provenance" "$version" "$build" "$tag" "$commit" "$artifact" "$digest" "$signer_authority" "$signer_team" <<'PY'
import json, sys
path, version, build, tag, commit, artifact, digest, signer_authority, signer_team = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as f: data = json.load(f)
except (OSError, ValueError) as e:
    raise SystemExit("Invalid provenance JSON: %s" % e)
expected = {"product":"AmpRunner", "marketing_version":version,
            "build_number":int(build), "tag":tag, "commit":commit,
            "artifact":artifact, "sha256":digest, "notarized":True}
signer_keys = {"developer_id_authority", "developer_team"}
authority = data.get("developer_id_authority")
if (set(data) != set(expected) | signer_keys or any(data.get(k) != v for k,v in expected.items())
        or not isinstance(authority, str) or not authority.startswith("Developer ID Application:")
        or not isinstance(data.get("developer_team"), str) or not data["developer_team"]
        or authority != signer_authority or data.get("developer_team") != signer_team):
    raise SystemExit("Provenance does not match the release")
PY
}
