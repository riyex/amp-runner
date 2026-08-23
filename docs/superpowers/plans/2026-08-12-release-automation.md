# Two-Phase macOS Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one command that creates verified signed/notarized DMG assets from an annotated release tag and a second command that pushes that tag and creates an idempotent draft GitHub Release.

**Architecture:** Small POSIX shell commands own release-checkout validation, archive creation, DMG packaging, notarization, asset/provenance validation, orchestration, and publication. Shell tests use temporary Git repositories and stub executables so CI verifies release invariants without Apple credentials or remote mutation.

**Tech Stack:** POSIX shell, Git, Xcode/XcodeGen, `codesign`, `hdiutil`, `xcrun notarytool`, `stapler`, `spctl`, Python 3 JSON handling, GitHub CLI, GitHub Actions.

---

## File map

- `Scripts/release_common.sh`: shared version parsing, tagged-checkout validation, artifact paths, checksum/provenance creation and validation.
- `Scripts/build_developer_id.sh`: build an archive with the committed build number and verify Developer ID signatures.
- `Scripts/package_dmg.sh`: create the drag-to-Applications compressed DMG from the signed app.
- `Scripts/notarize_dmg.sh`: submit, staple, and Gatekeeper-assess the DMG.
- `Scripts/prepare_release.sh`: phase 1 orchestration; this is the only local preparation entry point.
- `Scripts/publish_release.sh`: phase 2 validation, tag push, and draft GitHub Release creation/update.
- `Scripts/tests/release_common_test.sh`: release identity and provenance tests in temporary Git repositories.
- `Scripts/tests/build_developer_id_test.sh`: proves the archive command consumes and preserves the committed build number.
- `Scripts/tests/publish_release_test.sh`: publication state tests with stubbed `git`/`gh` behavior where needed.
- `Scripts/tests/run_release_tool_tests.sh`: one CI entry point for all shell release tests.
- `.github/workflows/ci.yml`, `.github/workflows/release-prep.yml`: run the complete release-tool test suite.
- `docs/RELEASING.md`, `README.md`, `ARCHITECTURE.md`: document the two phases and DMG distribution.
- Remove `Scripts/increment_build_number.sh` and `Scripts/tests/increment_build_number_test.sh`.

### Task 1: Release identity and provenance primitives

**Files:**
- Create: `Scripts/release_common.sh`
- Create: `Scripts/tests/release_common_test.sh`

- [ ] **Step 1: Write failing shell cases**

Create temporary Git repositories and assert that `validate_release_checkout v1.2.3`
accepts only a clean detached checkout at an annotated tag whose `project.yml` contains
`MARKETING_VERSION: "1.2.3"` and integer `CURRENT_PROJECT_VERSION`. Add cases rejecting a
branch checkout, lightweight tag, dirty checkout, malformed tag, mismatched version, and
invalid build. Add an asset round-trip that generates and validates checksum/provenance,
then rejects a modified DMG and altered manifest.

- [ ] **Step 2: Run the test and observe the missing implementation failure**

Run: `./Scripts/tests/release_common_test.sh`
Expected: nonzero exit because `Scripts/release_common.sh` does not exist.

- [ ] **Step 3: Implement the shared functions**

Implement these stable shell interfaces:

```sh
validate_release_checkout TAG [PROJECT_FILE]
release_artifact_paths TAG [BUILD_DIR]
create_release_metadata TAG DMG CHECKSUM PROVENANCE SIGNED_BY [PROJECT_FILE]
validate_release_assets TAG DMG CHECKSUM PROVENANCE [PROJECT_FILE]
```

`validate_release_checkout` prints `VERSION BUILD COMMIT` separated by tabs only after all
invariants pass. `release_artifact_paths` prints DMG, checksum, and provenance paths on
separate lines. Metadata functions use `shasum -a 256` and `python3` for strict JSON.

- [ ] **Step 4: Run the focused tests**

Run: `./Scripts/tests/release_common_test.sh`
Expected: `Release common tests passed`.

- [ ] **Step 5: Commit**

```sh
git add Scripts/release_common.sh Scripts/tests/release_common_test.sh
git commit -m "feat(release): validate tagged release identity"
```

### Task 2: Provenance-safe Developer ID archive

**Files:**
- Modify: `Scripts/build_developer_id.sh`
- Create: `Scripts/tests/build_developer_id_test.sh`
- Delete: `Scripts/increment_build_number.sh`
- Delete: `Scripts/tests/increment_build_number_test.sh`

- [ ] **Step 1: Write the archive behavior test**

Stub `generate_project.sh`, `xcodebuild`, and `codesign`; invoke the archive script against
a temporary `project.yml` with build `41`; assert `xcodebuild` receives
`CURRENT_PROJECT_VERSION=41` and the project file's hash does not change. Add an invalid
build case that proves `xcodebuild` is never called.

- [ ] **Step 2: Run the test and observe the incrementing behavior failure**

Run: `./Scripts/tests/build_developer_id_test.sh`
Expected: nonzero exit because the current script edits `project.yml`.

- [ ] **Step 3: Change the archive script and remove the incrementer**

Read `CURRENT_PROJECT_VERSION` from `PROJECT_FILE` (default `project.yml`), validate it as
a non-negative integer, print `Building release <marketing-version> (<build>)`, and pass it
to `xcodebuild`. Keep helper-first signature verification and add Hardened Runtime and
`get-task-allow` checks for the final app.

- [ ] **Step 4: Run both archive and common tests**

Run: `./Scripts/tests/build_developer_id_test.sh && ./Scripts/tests/release_common_test.sh`
Expected: both test scripts pass and `git diff -- project.yml` is empty.

- [ ] **Step 5: Commit**

```sh
git add Scripts/build_developer_id.sh Scripts/tests/build_developer_id_test.sh
git rm Scripts/increment_build_number.sh Scripts/tests/increment_build_number_test.sh
git commit -m "fix(release): preserve committed build number"
```

### Task 3: DMG packaging, notarization, and phase 1 orchestration

**Files:**
- Create: `Scripts/package_dmg.sh`
- Create: `Scripts/notarize_dmg.sh`
- Create: `Scripts/prepare_release.sh`
- Extend: `Scripts/tests/release_common_test.sh`

- [ ] **Step 1: Add command-contract tests**

Use command stubs to assert the packager stages `AmpRunner.app` and an `Applications`
symlink, invokes `hdiutil create` then `hdiutil convert`, and atomically replaces the
requested DMG. Assert notarization invokes `notarytool submit --wait`, `stapler staple`,
`stapler validate`, and `spctl --type open`. Assert preparation validates before invoking
tests/build, invokes each phase in order, and does not create metadata after notarization
failure.

- [ ] **Step 2: Run tests and observe missing-command failures**

Run: `./Scripts/tests/release_common_test.sh`
Expected: nonzero exit because the three commands do not exist.

- [ ] **Step 3: Implement the focused scripts**

`package_dmg.sh APP DMG` creates a private temporary staging directory under `BUILD_DIR`,
copies the app with `ditto`, creates `Applications -> /Applications`, builds a temporary
read-write HFS+ image, converts it to compressed UDZO, and moves it to `DMG`.

`notarize_dmg.sh DMG` requires the file and uses `NOTARY_PROFILE` (default
`AmpRunner Notary`) for submission, then staples and assesses it.

`prepare_release.sh TAG` validates tools and checkout, removes only that version's stale
publishable outputs, runs all tests/resource checks, builds the archive, packages and
notarizes the DMG, extracts the complete Developer ID authority from the app, creates
metadata, validates it, and prints the three asset paths.

- [ ] **Step 4: Run all available shell tests**

Run: `./Scripts/tests/release_common_test.sh && ./Scripts/tests/build_developer_id_test.sh`
Expected: both pass without certificates or network access.

- [ ] **Step 5: Commit**

```sh
git add Scripts/package_dmg.sh Scripts/notarize_dmg.sh Scripts/prepare_release.sh Scripts/tests/release_common_test.sh
git commit -m "feat(release): prepare notarized DMG assets"
```

### Task 4: Phase 2 draft GitHub publication

**Files:**
- Create: `Scripts/publish_release.sh`
- Create: `Scripts/tests/publish_release_test.sh`
- Create: `Scripts/tests/run_release_tool_tests.sh`

- [ ] **Step 1: Write publication state tests**

Create a tagged temporary repository and valid fake assets. Stub `gh` and the remote Git
operations to verify: a missing remote tag is pushed before draft creation; a matching
remote tag is not pushed; a conflicting tag fails before `gh release`; an existing draft
uses `gh release upload --clobber`; an existing published release fails; and all local
asset failures happen before any remote command.

- [ ] **Step 2: Run tests and observe the missing publisher failure**

Run: `./Scripts/tests/publish_release_test.sh`
Expected: nonzero exit because `Scripts/publish_release.sh` does not exist.

- [ ] **Step 3: Implement fail-closed publication**

Validate checkout and assets first. Require `gh auth status`. Derive the GitHub repository
from `gh repo view --json nameWithOwner`. Require `origin` to normalize to that repository.
Use `git ls-remote` peeled-tag output to detect missing, matching, or conflicting tags.
Push only a missing tag. Query `gh release view --json isDraft`; create a missing draft
with generated notes and all assets, upload with `--clobber` to an existing draft, and
reject `isDraft: false`.

- [ ] **Step 4: Add and run the aggregate test entry point**

`run_release_tool_tests.sh` executes the release-branch validator plus all new shell test
files. Run: `./Scripts/tests/run_release_tool_tests.sh`
Expected: every shell suite passes.

- [ ] **Step 5: Commit**

```sh
git add Scripts/publish_release.sh Scripts/tests/publish_release_test.sh Scripts/tests/run_release_tool_tests.sh
git commit -m "feat(release): publish verified draft releases"
```

### Task 5: CI and maintainer documentation

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release-prep.yml`
- Modify: `docs/RELEASING.md`
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Make CI run the aggregate shell suite**

Replace direct release-validator invocations in both workflows with
`./Scripts/tests/run_release_tool_tests.sh`. Keep unsigned archive creation and read-only
permissions unchanged.

- [ ] **Step 2: Rewrite the release runbook**

Document committed version/build preparation, annotated tag creation, detached checkout,
Keychain setup, phase 1 invocation, mounted-DMG smoke testing, phase 2 invocation, draft
review, and manual publication. State explicitly that Phase 2 pushes a missing tag and
never publishes the draft.

- [ ] **Step 3: Update short project references**

Replace ZIP/direct-archive wording in README and architecture documentation with the
signed/notarized DMG and two-phase commands. Preserve existing security and App Store
guidance.

- [ ] **Step 4: Run full verification**

Run:

```sh
./Scripts/tests/run_release_tool_tests.sh
swift test
plutil -lint App/Resources/Info.plist
find App/Resources/Assets.xcassets -name Contents.json -print0 | xargs -0 -n1 jq empty
./Scripts/generate_project.sh
git diff --check
```

Expected: all commands exit zero; Swift reports 122 or more passing tests; XcodeGen creates
the ignored project without changing tracked files.

- [ ] **Step 5: Commit**

```sh
git add .github/workflows/ci.yml .github/workflows/release-prep.yml docs/RELEASING.md README.md ARCHITECTURE.md
git commit -m "docs(release): document two-phase DMG workflow"
```

### Task 6: Final review and release-safety verification

**Files:**
- Review all files changed since the design commit.

- [ ] **Step 1: Inspect the complete diff**

Run: `git diff 9110a3b^..HEAD --check && git status --short`
Expected: no whitespace errors and no unexplained files.

- [ ] **Step 2: Review high-risk invariants**

Confirm no command edits `project.yml`, Phase 1 performs no remote mutation, Phase 2 does
no signing/notarization, published releases fail closed, shell paths are quoted, temporary
directories have cleanup traps, and secrets never appear in arguments except the Keychain
profile name.

- [ ] **Step 3: Run final verification from a clean tree**

Run: `./Scripts/tests/run_release_tool_tests.sh && swift test && git diff --check`
Expected: all checks pass.

- [ ] **Step 4: Request code review**

Review the implementation against
`docs/superpowers/specs/2026-08-12-release-automation-design.md`; fix any correctness or
safety findings and rerun the focused tests.

- [ ] **Step 5: Record final state**

Run: `git log --oneline --decorate -7 && git status --short`
Expected: reviewable contextual commits and a clean worktree.
