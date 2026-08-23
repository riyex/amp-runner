# Two-Phase macOS Release Automation Design

## Goal

Make Amp Runner releases repeatable without placing Apple signing or notarization
credentials in GitHub. A maintainer will first produce and verify local release assets,
then run a separate command to push the tag and create or update a draft GitHub Release.

## Release identity and trust boundary

The release commit is the sole source of the marketing version and build number. Before
tagging, the maintainer commits `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`project.yml`. Release builds read those values and never edit tracked files.

Phase 1 requires an existing local annotated tag named `vX.Y.Z`. The maintainer must run
it from a clean, detached checkout whose `HEAD` is exactly that tag. The script rejects a
branch checkout, a lightweight tag, a mismatched tag or marketing version, a non-integer
build number, and tracked or untracked worktree changes. These constraints tie every
artifact to an immutable source identity.

Apple credentials remain in the maintainer's Keychain. GitHub Actions continues to build
only unsigned diagnostic archives. Phase 2 uses GitHub CLI authentication but has no
access to Apple credentials.

```diagram
┌───────────────────────────────┐
│ Committed version and build   │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│ Local annotated vX.Y.Z tag    │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│ Phase 1: prepare local assets │
│ sign → DMG → notarize → prove │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│ Phase 2: publish draft        │
│ push tag → upload assets      │
└───────────────────────────────┘
```

## Phase 1: prepare verified local assets

`Scripts/prepare_release.sh vX.Y.Z` is the maintainer-facing entry point. It performs the
following operations in order and stops at the first failure:

1. Validate the host tools and release checkout.
2. Run Swift tests, release-tool tests, property-list validation, and asset-catalog
   validation.
3. Build a Developer ID archive using the committed version and build number.
4. Verify the app and embedded monitor with `codesign`.
5. Confirm the expected Developer ID Application authority, Hardened Runtime, and absence
   of the development-only `get-task-allow` entitlement.
6. Package the signed app in a drag-to-Applications DMG.
7. Submit the DMG to Apple's notarization service, wait for acceptance, staple its ticket,
   and validate it with `stapler` and Gatekeeper.
8. Generate and validate the checksum and provenance manifest.

The command accepts Apple configuration through environment variables:

- `DEVELOPMENT_TEAM` is required.
- `CODE_SIGN_IDENTITY` defaults to `Developer ID Application` and may contain the full
  certificate name when the Keychain contains multiple identities.
- `NOTARY_PROFILE` defaults to `AmpRunner Notary`.
- `BUILD_DIR` defaults to the repository's `build` directory.

The existing `Scripts/build_developer_id.sh` remains the focused archive command. It reads
`CURRENT_PROJECT_VERSION` from `project.yml`, passes that value to `xcodebuild`, and fails
if it is missing or invalid. It does not increment the value or modify `project.yml`.

A focused DMG packager creates a temporary read-write image containing `AmpRunner.app`
and an `Applications` symlink to `/Applications`, then converts it to a compressed UDIF
image. It replaces only temporary and output paths inside `BUILD_DIR`; it never changes
the archived app or tracked files. The layout and inputs are deterministic, but byte-for-
byte DMG reproducibility is not promised because `hdiutil` writes filesystem and container
metadata.

A focused notarization command submits the DMG with `xcrun notarytool submit --wait`, then
staples and validates the DMG. Notarization failure leaves the DMG available for diagnosis
but prevents checksum and provenance generation.

The successful command produces exactly these publishable assets:

- `AmpRunner-X.Y.Z.dmg`
- `AmpRunner-X.Y.Z.dmg.sha256`
- `AmpRunner-X.Y.Z.provenance.json`

The checksum file uses the artifact's base name rather than an absolute path. The JSON
manifest records the product, marketing version, integer build number, tag, full commit
SHA, artifact name, SHA-256, complete Developer ID authority, and `notarized: true`.
The script writes JSON with a system JSON tool rather than shell interpolation so identity
names are escaped correctly.

## Phase 2: create the draft GitHub Release

`Scripts/publish_release.sh vX.Y.Z` is the only release command that changes remote state.
It does not build, sign, notarize, or alter local artifacts.

Before contacting GitHub, it repeats the release identity checks and verifies:

- all three expected assets exist;
- the checksum matches the DMG;
- every provenance field matches the tag, commit, committed version/build, artifact name,
  checksum, and notarized state;
- `gh` is installed and authenticated;
- `origin` is the expected GitHub repository for the current checkout.

The script then compares the local tag with `refs/tags/vX.Y.Z` on `origin`. It pushes a
missing tag. It accepts an existing tag only when its peeled commit matches the local tag,
and rejects a conflict.

After the tag is available remotely, the script creates a draft GitHub Release with
generated release notes and uploads the DMG, checksum, and provenance manifest. On a
rerun, it updates an existing draft and replaces matching assets. It refuses to alter an
already-published release. The script never publishes the draft; final release publication
remains a deliberate GitHub action after smoke testing.

## Error handling and reruns

Every shell script uses strict error handling, quotes paths, resolves the repository root
from its own location, and validates required commands before doing expensive or remote
work. Error messages identify the failed invariant and the corrective action.

Phase 1 removes stale outputs for the requested version before rebuilding. It keeps the
archive and rejected DMG when Apple or Gatekeeper rejects the artifact, which preserves
diagnostic evidence. A successful rerun replaces all three publishable assets.

Phase 2 performs all local validation before pushing the tag. Once the tag is pushed, a
GitHub API failure may leave a remote tag without a release; rerunning the command creates
the missing draft. Matching remote state is idempotent, while conflicting or published
state fails closed.

## Tests and continuous integration

Shell tests cover logic that does not require certificates, Apple credentials, or remote
mutation. Tests use temporary repositories, files, and command stubs to verify:

- release-tag syntax, annotated-tag enforcement, detached checkout enforcement, clean
  checkout enforcement, and tag/version/build consistency;
- the archive script consumes the committed build number without changing `project.yml`;
- checksum and provenance generation and validation;
- publication behavior for missing, matching, and conflicting remote tags and for absent,
  draft, and published GitHub Releases;
- failure paths stop before the first signing, notarization, or remote mutation command.

Both CI and Release Preparation run the complete release-tool test suite. CI does not run
Developer ID signing, DMG notarization, or GitHub publication.

## Documentation and migration

`docs/RELEASING.md` becomes the authoritative two-phase runbook. It covers committing the
version and build number, merging the release PR, creating the local annotated tag,
checking out the tag in detached mode, running both commands, smoke testing the mounted
DMG, reviewing the draft, and publishing it in GitHub.

The obsolete build-number increment script and its tests are removed. README and
architecture references are updated where they describe the old direct archive or ZIP
workflow. The Release Preparation workflow remains unsigned and never publishes an
artifact intended for distribution.

## Out of scope

- Storing Developer ID certificates or notarization credentials in GitHub.
- Automatically publishing a GitHub Release.
- Building a signed `.pkg` installer.
- Promising byte-for-byte reproducible DMG files.
- Automatically editing, committing, or tagging release versions.
- Uploading the release to Homebrew or another distribution service.
