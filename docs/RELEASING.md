# Releasing Amp Runner

Releases are built, signed, and notarized on the maintainer's Mac. GitHub Actions validates
release branches and produces an unsigned diagnostic archive; it does not hold signing
credentials or publish binaries.

## 1. Prepare the release branch

Start from an up-to-date `main`:

```sh
git switch main
git pull --ff-only
git switch -c release/X.Y.Z
```

Set `MARKETING_VERSION` in `project.yml` to `X.Y.Z`. Increment
`CURRENT_PROJECT_VERSION`; it is an integer build number and must increase for every build
submitted to Apple services, including retries that change the binary.

Validate the branch name against the project:

```sh
./Scripts/validate_release_branch.sh release/X.Y.Z
```

Commit and push the version change. The Release Preparation workflow runs tests, validates
the project, and uploads an artifact named `unsigned-not-for-distribution`. It is useful
for inspecting archive structure only. Do not distribute or notarize that artifact.

Merge the release branch after its checks pass. Update the local `main` and perform every
remaining step from the exact commit that will be tagged:

```sh
git switch main
git pull --ff-only
test "$(./Scripts/validate_release_branch.sh release/X.Y.Z)" = "X.Y.Z"
```

Do not merge another change into `main` until the release is tagged, or restart the build
from the new commit.

## 2. Archive and verify signatures

The archive script requests a Developer ID Application identity and rejects an archive
whose helper or app has any other authority. Set `CODE_SIGN_IDENTITY` to a full identity
name if Xcode has more than one Developer ID certificate available:

```sh
rm -rf build/AmpRunner.xcarchive
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  ARCHIVE_PATH="$PWD/build/AmpRunner.xcarchive" \
  ./Scripts/build_developer_id.sh
```

Find the team ID in the Apple Developer portal or the parenthesized suffix of
`security find-identity -v -p codesigning`. The team ID is not a credential, but keeping it
outside `project.yml` lets each maintainer sign with their own account.

Verify the helper first, then the containing app:

```sh
APP="$PWD/build/AmpRunner.xcarchive/Products/Applications/AmpRunner.app"
codesign --verify --strict --verbose=2 "$APP/Contents/Helpers/AmpRunnerMonitor"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP"
```

Confirm that the displayed authority is the intended Developer ID and that Hardened
Runtime is enabled.

## 3. Notarize and assess

Create the Keychain profile once; do not put App Store Connect credentials in this
repository or in shell history:

```sh
xcrun notarytool store-credentials "AmpRunner Notary"
```

Submit a temporary ZIP, wait for Apple, and staple the accepted ticket:

```sh
ditto -c -k --keepParent "$APP" build/AmpRunner-notarization.zip
xcrun notarytool submit \
  build/AmpRunner-notarization.zip \
  --keychain-profile "AmpRunner Notary" \
  --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
```

Stop if any signature, notarization, stapling, or Gatekeeper check fails.

## 4. Package and smoke-test

Create the distributable and checksum from the stapled app:

```sh
VERSION=X.Y.Z
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" \
  "build/AmpRunner-$VERSION.zip"
(cd build && \
  shasum -a 256 "AmpRunner-$VERSION.zip" > "AmpRunner-$VERSION.sha256")
```

Extract that ZIP into a clean directory. Launch the extracted app, create a disposable
profile, start and stop a runner, inspect its logs, and quit the app while a runner is
active to confirm the bundled monitor stops it.

## 5. Tag and publish

Only tag the commit whose packaged app passed every preceding check:

```sh
git status --short
git tag -a "v$VERSION" -m "Amp Runner $VERSION"
git push origin "v$VERSION"
```

Create the GitHub Release for that tag. Attach the notarized ZIP and `.sha256` file, and
describe user-visible changes and known limitations. Never attach the unsigned workflow
artifact.
