#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
COMMON="$ROOT/Scripts/release_common.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

[ -f "$COMMON" ] || { echo "missing release_common.sh" >&2; exit 1; }
. "$COMMON"

make_repo() {
    repo=$1
    mkdir "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    printf 'settings:\n  MARKETING_VERSION: "1.2.3"\n  CURRENT_PROJECT_VERSION: "41"\n' > "$repo/project.yml"
    git -C "$repo" add project.yml
    git -C "$repo" commit -qm initial
    git -C "$repo" tag -a v1.2.3 -m release
    git -C "$repo" checkout -q --detach v1.2.3
}

make_repo "$TMP/good"
actual=$(cd "$TMP/good" && validate_release_checkout v1.2.3)
[ "$actual" = "1.2.3	41	$(git -C "$TMP/good" rev-parse HEAD)" ]

reject() { if (cd "$1" && validate_release_checkout "$2" ${3+"$3"}) >/dev/null 2>&1; then echo "accepted invalid checkout: $1" >&2; exit 1; fi; }

git -C "$TMP/good" checkout -q -b branch
reject "$TMP/good" v1.2.3
git -C "$TMP/good" checkout -q --detach v1.2.3
printf dirty >> "$TMP/good/untracked"
reject "$TMP/good" v1.2.3
rm "$TMP/good/untracked"
reject "$TMP/good" 1.2.3

make_repo "$TMP/light"
git -C "$TMP/light" tag -d v1.2.3 >/dev/null
git -C "$TMP/light" tag v1.2.3
reject "$TMP/light" v1.2.3

for kind in version build; do
    make_repo "$TMP/$kind"
    git -C "$TMP/$kind" checkout -q main
    if [ "$kind" = version ]; then
        sed 's/1.2.3/1.2.4/' "$TMP/$kind/project.yml" > "$TMP/$kind/p" && mv "$TMP/$kind/p" "$TMP/$kind/project.yml"
    else
        sed 's/"41"/"bad"/' "$TMP/$kind/project.yml" > "$TMP/$kind/p" && mv "$TMP/$kind/p" "$TMP/$kind/project.yml"
    fi
    git -C "$TMP/$kind" add . && git -C "$TMP/$kind" commit -qm bad
    git -C "$TMP/$kind" tag -f -a v1.2.3 -m bad
    git -C "$TMP/$kind" checkout -q --detach v1.2.3
    reject "$TMP/$kind" v1.2.3
done

cd "$TMP/good"
printf 'AmpRunner-*\n' >> .git/info/exclude
printf payload > AmpRunner-1.2.3.dmg
create_release_metadata v1.2.3 AmpRunner-1.2.3.dmg AmpRunner-1.2.3.dmg.sha256 AmpRunner-1.2.3.provenance.json 'Developer ID Application: Example (TEAM)' TEAM
cat > "$TMP/codesign" <<'EOF'
#!/bin/sh
printf 'Authority=%s\nTeamIdentifier=%s\n' "${MOCK_AUTHORITY:-Developer ID Application: Example (TEAM)}" "${MOCK_TEAM:-TEAM}" >&2
EOF
chmod +x "$TMP/codesign"
CODESIGN_COMMAND="$TMP/codesign" validate_release_assets v1.2.3 AmpRunner-1.2.3.dmg AmpRunner-1.2.3.dmg.sha256 AmpRunner-1.2.3.provenance.json
cp AmpRunner-1.2.3.provenance.json "$TMP/provenance"
python3 -c 'import json; p="AmpRunner-1.2.3.provenance.json"; d=json.load(open(p)); d["developer_id_authority"]="Developer ID Application: Attacker (EVIL)"; json.dump(d,open(p,"w"))'
if CODESIGN_COMMAND="$TMP/codesign" validate_release_assets v1.2.3 AmpRunner-1.2.3.dmg AmpRunner-1.2.3.dmg.sha256 AmpRunner-1.2.3.provenance.json >/dev/null 2>&1; then echo accepted altered signer authority >&2; exit 1; fi
mv "$TMP/provenance" AmpRunner-1.2.3.provenance.json
if MOCK_AUTHORITY='Developer ID Application: Attacker (EVIL)' CODESIGN_COMMAND="$TMP/codesign" validate_release_assets v1.2.3 AmpRunner-1.2.3.dmg AmpRunner-1.2.3.dmg.sha256 AmpRunner-1.2.3.provenance.json >/dev/null 2>&1; then echo accepted DMG signer mismatch >&2; exit 1; fi
cp AmpRunner-1.2.3.dmg "$TMP/dmg"
printf changed >> AmpRunner-1.2.3.dmg
if CODESIGN_COMMAND="$TMP/codesign" validate_release_assets v1.2.3 AmpRunner-1.2.3.dmg AmpRunner-1.2.3.dmg.sha256 AmpRunner-1.2.3.provenance.json >/dev/null 2>&1; then echo accepted modified DMG >&2; exit 1; fi
mv "$TMP/dmg" AmpRunner-1.2.3.dmg
python3 -c 'import json; p="AmpRunner-1.2.3.provenance.json"; d=json.load(open(p)); d["build_number"]=42; json.dump(d,open(p,"w"))'
if CODESIGN_COMMAND="$TMP/codesign" validate_release_assets v1.2.3 AmpRunner-1.2.3.dmg AmpRunner-1.2.3.dmg.sha256 AmpRunner-1.2.3.provenance.json >/dev/null 2>&1; then echo accepted altered manifest >&2; exit 1; fi

[ -x "$ROOT/Scripts/package_dmg.sh" ] || { echo missing package_dmg.sh >&2; exit 1; }
[ -x "$ROOT/Scripts/notarize_dmg.sh" ] || { echo missing notarize_dmg.sh >&2; exit 1; }
[ -x "$ROOT/Scripts/prepare_release.sh" ] || { echo missing prepare_release.sh >&2; exit 1; }

mkdir -p "$TMP/package/app/AmpRunner.app" "$TMP/package/bin" "$TMP/package/build"
cat > "$TMP/package/bin/ditto" <<'EOF'
#!/bin/sh
printf 'ditto %s\n' "$*" >> "$COMMAND_LOG"
cp -R "$1" "$2"
EOF
cat > "$TMP/package/bin/hdiutil" <<'EOF'
#!/bin/sh
printf 'hdiutil %s\n' "$*" >> "$COMMAND_LOG"
case "$1" in create) eval "out=\${$#}"; : > "$out";; convert) while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { shift; : > "$1"; }; shift; done;; esac
EOF
chmod +x "$TMP/package/bin/"*
COMMAND_LOG="$TMP/package/log" BUILD_DIR="$TMP/package/build" DITTO_COMMAND="$TMP/package/bin/ditto" HDIUTIL_COMMAND="$TMP/package/bin/hdiutil" "$ROOT/Scripts/package_dmg.sh" "$TMP/package/app/AmpRunner.app" "$TMP/package/out.dmg"
[ -f "$TMP/package/out.dmg" ]
grep -q 'hdiutil create' "$TMP/package/log" && grep -q 'hdiutil convert' "$TMP/package/log"

cat > "$TMP/package/bin/xcrun" <<'EOF'
#!/bin/sh
printf 'xcrun %s\n' "$*" >> "$COMMAND_LOG"
EOF
cat > "$TMP/package/bin/spctl" <<'EOF'
#!/bin/sh
printf 'spctl %s\n' "$*" >> "$COMMAND_LOG"
EOF
chmod +x "$TMP/package/bin/"*
COMMAND_LOG="$TMP/package/notary-log" XCRUN_COMMAND="$TMP/package/bin/xcrun" SPCTL_COMMAND="$TMP/package/bin/spctl" "$ROOT/Scripts/notarize_dmg.sh" "$TMP/package/out.dmg"
grep -q 'notarytool submit .*--wait' "$TMP/package/notary-log"
grep -q 'stapler staple' "$TMP/package/notary-log"
grep -q 'stapler validate' "$TMP/package/notary-log"
grep -q 'spctl.*--type open' "$TMP/package/notary-log"

echo "Release common tests passed"
