# Contributing

Amp Runner welcomes focused bug fixes, tests, and improvements. Open an issue before
starting a large change so the design can be agreed before either side invests substantial
time.

## Development setup

You need macOS 14 or later, Xcode 15 or later, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
git clone https://github.com/riyex/amp-runner.git
cd amp-runner
swift test
./Scripts/generate_project.sh
open AmpRunner.xcodeproj
```

`AmpRunner.xcodeproj` is generated from `project.yml` and ignored by Git. Change
`project.yml`, not the generated project, and do not commit the project directory.

The core and process-monitor code retain some Linux portability plumbing, but Linux is not
a supported or tested development target. Pull requests that improve Linux portability
are welcome when they preserve macOS behavior.

## Before opening a pull request

Run the same checks as CI:

```sh
./Scripts/tests/validate_release_branch_test.sh
swift test
plutil -lint App/Resources/Info.plist
find App/Resources/Assets.xcassets -name Contents.json -print0 | xargs -0 -n1 jq empty
./Scripts/generate_project.sh
xcodebuild \
  -project AmpRunner.xcodeproj \
  -scheme AmpRunner \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Keep changes limited to one purpose. Add tests for behavior changes, and update user or
maintainer documentation when a workflow changes. Explain the problem and the reason for
your approach in the pull-request description.

## Contribution terms

By submitting a contribution, you agree that it is licensed under the
[Apache License 2.0](LICENSE), as described in section 5 of that license. Amp Runner does
not require a separate contributor license agreement or Developer Certificate of Origin
sign-off.
