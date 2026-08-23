# Releasing Amp Runner

Releases use two local commands. The first builds, signs, packages, notarizes, and verifies
a DMG. The second pushes the release tag and creates or updates a draft GitHub Release.
Apple credentials stay in the maintainer's Keychain; GitHub Actions produces only an
unsigned diagnostic archive.

## 1. Commit the release identity

Start from an up-to-date `main` and create a release branch:

```sh
git switch main
git pull --ff-only
git switch -c release/X.Y.Z
```

Set both release values in `project.yml` before tagging or building:

```yaml
MARKETING_VERSION: "X.Y.Z"
CURRENT_PROJECT_VERSION: "N"
```

`CURRENT_PROJECT_VERSION` is a non-negative integer. Increase it for every binary submitted
to Apple's notarization service, including a retry that changes the binary. Release scripts
read this committed value and never increment or edit it.

Validate, commit, and push the branch:

```sh
./Scripts/validate_release_branch.sh release/X.Y.Z
git add project.yml
git commit -m "chore(release): prepare X.Y.Z"
git push -u origin release/X.Y.Z
```

The Release Preparation workflow runs tests and creates an unsigned artifact named
`unsigned-not-for-distribution`. Use it only to inspect archive structure. Never distribute
or notarize it.

Merge the approved release PR, update local `main`, and pause other merges until the draft
release exists:

```sh
git switch main
git pull --ff-only
```

## 2. Create and check out the local tag

Create an annotated tag on the merged release commit. A signed annotated tag is also
accepted when Git signing is configured.

```sh
VERSION=X.Y.Z
git status --short
git tag -a "v$VERSION" -m "Amp Runner $VERSION"
git switch --detach "v$VERSION"
git describe --exact-match --tags
git rev-parse HEAD
```

Do not push the tag yet. Phase 1 requires a clean detached checkout exactly at this
annotated tag and rejects a branch checkout, lightweight tag, version mismatch, or
uncommitted file.

## 3. Configure the maintainer Mac

Install the intended Developer ID Application certificate in the login Keychain. Find its
team ID in the Apple Developer portal or in the parenthesized suffix printed by:

```sh
security find-identity -v -p codesigning
```

Store notarization credentials once. The profile contains the credential; its name is not
a secret.

```sh
xcrun notarytool store-credentials "AmpRunner Notary"
```

Install the local build dependencies if needed:

```sh
brew install xcodegen
gh auth login
```

## 4. Phase 1: prepare local release assets

Run the preparation command from the detached tag checkout:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ./Scripts/prepare_release.sh "v$VERSION"
```

Optional environment variables:

- `CODE_SIGN_IDENTITY` selects a full Developer ID identity when the Keychain contains
  more than one; it defaults to `Developer ID Application`.
- `NOTARY_PROFILE` selects a `notarytool` Keychain profile; it defaults to
  `AmpRunner Notary`.
- `BUILD_DIR` changes the output directory; it defaults to `build`.

Phase 1 runs release-tool and Swift tests, validates resources, builds the app and embedded
monitor with the committed build number, verifies Developer ID signatures and Hardened
Runtime, rejects `get-task-allow`, creates and signs a drag-to-Applications DMG, notarizes
and staples the DMG, runs Gatekeeper assessment, and validates all metadata. It produces:

```text
build/AmpRunner-X.Y.Z.dmg
build/AmpRunner-X.Y.Z.dmg.sha256
build/AmpRunner-X.Y.Z.provenance.json
```

Stop if any command fails. The script does not push a tag or change GitHub state.

## 5. Smoke-test the DMG

Mount `build/AmpRunner-X.Y.Z.dmg` and confirm that it contains `AmpRunner.app` and an
`Applications` alias. Drag the app into an empty temporary directory that represents
Applications, then test the copied app rather than the archived app:

1. Launch it through Finder so Gatekeeper evaluates it.
2. Create a disposable profile.
3. Start and stop a runner and inspect its logs.
4. Start another runner, quit Amp Runner, and confirm the bundled monitor stops the runner.
5. Eject the image.

Rebuild with a new committed `CURRENT_PROJECT_VERSION` if testing reveals a change that
requires another binary.

## 6. Phase 2: create the draft GitHub Release

After the smoke test passes, run:

```sh
./Scripts/publish_release.sh "v$VERSION"
```

Phase 2 revalidates the local tag, checksum, and provenance before contacting GitHub. It
then:

1. confirms that `origin` matches the repository authenticated through `gh`;
2. pushes the tag if it is missing, or verifies that an existing remote tag resolves to
   the same commit;
3. creates a draft release with generated notes, or replaces assets on an existing draft;
4. uploads the DMG, checksum, and provenance manifest.

The command rejects conflicting remote tags and already-published releases. It never
publishes the draft. If GitHub fails after the tag push, rerun the same command; matching
remote state is safe and the draft creation or asset upload resumes.

## 7. Review and publish

Open the draft on GitHub. Check its tag and commit, edit generated notes, download all
three assets, verify the checksum, and repeat the Gatekeeper launch from the downloaded
DMG. Publish the draft through GitHub only after these checks pass.

Never attach the unsigned GitHub Actions artifact to a public release.
