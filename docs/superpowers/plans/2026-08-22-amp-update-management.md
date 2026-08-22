# Amp Update Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centrally discover and install Amp CLI releases, record the Amp version used by each runner launch, and persistently guide or automatically restart outdated runners without interrupting active work.

**Architecture:** `AmpUpdateController` is the app-wide release, executable-probe, and install executor. `RunnerCoordinator` joins that shared state to profiles and owns aggregate notifications plus idle-restart orchestration. `ProcessSupervisor` receives a generic async version provider and publishes only the version captured for its current process. Parsing, comparison, preferences, display-state derivation, notification planning, and restart decisions remain Foundation-only in `AmpRunnerCore`.

**Tech Stack:** Swift 5.9, SwiftPM, SwiftUI, Combine, Foundation `URLSession`/`Process`, UserNotifications, XcodeGen, XCTest

## Global Constraints

- Preserve the menu-bar-only app and macOS 14 deployment target.
- Use one app-wide release schedule: three seconds after launch, then hourly; never add a supervisor timer, profile timer, or file watcher.
- Fetch `https://static.ampcode.com/cli/cli-version.txt` with a five-second timeout and cache bypass.
- Invoke configured executables directly, never through a shell.
- Install only with `<configured executable> update --porcelain`.
- Accept only exact trimmed success output: `updated <version>` or `no update needed` with exit status zero.
- Do not run a second `amp version` probe after `updated <version>`.
- Deduplicate probes and installs by standardized absolute executable path.
- Keep captured stdout/stderr bounded; do not retain updater logs in published controller state.
- Never inject update messages into Amp threads.
- Keep runner health separate from update health and leave the aggregate menu-bar health icon unchanged.
- Never automatically interrupt `.working` or `.starting` runners.
- Keep stopped runners stopped after an install.
- Use the `contextual-commit` skill before composing each implementation commit.

---

### Task 1: Define the Amp version and updater contracts in Core

**Files:**
- Create: `Sources/AmpRunnerCore/AmpVersion.swift`
- Create: `Sources/AmpRunnerCore/AmpUpdateOutput.swift`
- Test: `Tests/AmpRunnerCoreTests/AmpVersionTests.swift`
- Test: `Tests/AmpRunnerCoreTests/AmpUpdateOutputTests.swift`

**Interfaces:**
- Produces: `AmpVersion`, `AmpReleaseResponse`, `AmpVersionCommandOutput`, `AmpUpdateOutput`
- Consumes: endpoint bytes, `amp version` stdout, and `amp update --porcelain` stdout

- [x] **Step 1: Write failing parsing tests from the observed Amp formats**

Cover these cases without performing network or process work:

```swift
XCTAssertEqual(
    try AmpReleaseResponse.parse(Data("0.0.1787342526-gc11bfb\n".utf8)),
    AmpVersion("0.0.1787342526-gc11bfb")
)
XCTAssertEqual(
    try AmpVersionCommandOutput.parse(
        "0.0.1787227443-g56d703 (released 2026-08-20T12:04:03.000Z, 1d ago)\n"
    ),
    AmpVersion("0.0.1787227443-g56d703")
)
```

Reject empty output, invalid UTF-8, whitespace inside the endpoint value, missing numeric components, nonnumeric numeric components, empty prerelease labels, and arbitrary text before the version. The version-command parser may consume only the first whitespace-delimited token, but that token must itself be a valid `AmpVersion`.

- [x] **Step 2: Write failing comparison tests that mirror Amp**

Test numeric dot-separated components numerically, not lexicographically; normalize missing trailing numeric components as zero; compare prerelease labels only after numeric equality; and treat a release without a prerelease label as newer than the same numeric version with one.

```swift
XCTAssertLessThan(AmpVersion("0.0.9")!, AmpVersion("0.0.10")!)
XCTAssertEqual(AmpVersion("1.2")!, AmpVersion("1.2.0")!)
XCTAssertLessThan(AmpVersion("1.2.3-ga")!, AmpVersion("1.2.3-gb")!)
XCTAssertLessThan(AmpVersion("1.2.3-ga")!, AmpVersion("1.2.3")!)
```

Retain the exact original string for display and updater output while basing `Comparable` and `Hashable` on normalized components.

- [x] **Step 3: Write failing porcelain-output tests**

Require exact trimmed output and model the two success contracts explicitly:

```swift
XCTAssertEqual(
    try AmpUpdateOutput.parse("updated 0.0.1787342526-gc11bfb\n"),
    .updated(AmpVersion("0.0.1787342526-gc11bfb")!)
)
XCTAssertEqual(
    try AmpUpdateOutput.parse("no update needed\n"),
    .noUpdateNeeded
)
```

Reject `Updated ...`, extra lines, missing versions, extra words, and human-readable updater output.

- [x] **Step 4: Implement the minimal Foundation-only contracts**

Use throwing parse functions for external bytes/text and a failable initializer for in-memory literals. Make errors `Equatable` and `LocalizedError` so the app can show precise nonfatal failures.

- [x] **Step 5: Run focused tests and commit**

```sh
swift test --filter 'AmpVersionTests|AmpUpdateOutputTests'
```

Commit as `feat(updates): define Amp CLI update contracts`.

---

### Task 2: Add preferences, derived profile state, and aggregate policy to Core

**Files:**
- Create: `Sources/AmpRunnerCore/AmpUpdatePreferences.swift`
- Create: `Sources/AmpRunnerCore/AmpUpdatePreferencesStore.swift`
- Create: `Sources/AmpRunnerCore/AmpProfileUpdateState.swift`
- Create: `Sources/AmpRunnerCore/AmpIdleRestartPolicy.swift`
- Create: `Sources/AmpRunnerCore/AmpUpdateNotificationPolicy.swift`
- Test: `Tests/AmpRunnerCoreTests/AmpUpdatePreferencesStoreTests.swift`
- Test: `Tests/AmpRunnerCoreTests/AmpProfileUpdateStateTests.swift`
- Test: `Tests/AmpRunnerCoreTests/AmpIdleRestartPolicyTests.swift`
- Test: `Tests/AmpRunnerCoreTests/AmpUpdateNotificationPolicyTests.swift`

**Interfaces:**
- Produces: persisted global preferences and pure update/restart/notification decisions
- Consumes: `AmpVersion`, `RunnerStatus`, active-thread presence, and small aggregate snapshots

- [x] **Step 1: Write failing preference default and persistence tests**

Define one Codable value with the approved defaults:

```swift
public struct AmpUpdatePreferences: Codable, Equatable, Sendable {
    public var automaticallyChecksForUpdates = true
    public var sendsUpdateNotifications = true
    public var automaticallyInstallsUpdates = false
    public var restartsUpdatedRunnersWhenIdle = false

    public init(
        automaticallyChecksForUpdates: Bool = true,
        sendsUpdateNotifications: Bool = true,
        automaticallyInstallsUpdates: Bool = false,
        restartsUpdatedRunnersWhenIdle: Bool = false
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.sendsUpdateNotifications = sendsUpdateNotifications
        self.automaticallyInstallsUpdates = automaticallyInstallsUpdates
        self.restartsUpdatedRunnersWhenIdle = restartsUpdatedRunnersWhenIdle
    }
}
```

Follow `RunnerPathSettingsStore`: persist JSON `Data` in injectable `UserDefaults`, return defaults when absent, reject wrong stored types/malformed JSON without overwriting bytes, and round-trip all four values.

- [x] **Step 2: Write failing profile-state derivation tests**

Define a compact presentation model with cases carrying only information the UI needs:

```swift
public enum AmpProfileUpdateState: Equatable, Sendable {
    case versionUnknown
    case upToDate(AmpVersion)
    case updateAvailable(installed: AmpVersion, latest: AmpVersion)
    case installing(installed: AmpVersion?)
    case restartRequired(running: AmpVersion, installed: AmpVersion)
    case updateFailed(installed: AmpVersion?, message: String)
}
```

Test precedence explicitly: active installation for the shared executable; then running older than installed means restart required; then a failed install; then latest newer than installed means update available; otherwise up to date. This keeps restart required persistent after a later failed update attempt. Stopped profiles use installed version and never return restart required. Unknown/malformed versions never guess.

- [x] **Step 3: Write failing idle-restart decision tests**

Keep the policy independent of profiles and supervisors:

```swift
public struct AmpRunnerUpdateSnapshot: Equatable, Sendable {
    public let profileID: UUID
    public let status: RunnerStatus
    public let hasActiveThread: Bool
    public let runningVersion: AmpVersion?
    public let installedVersion: AmpVersion?
    public let restartInFlight: Bool
}
```

Given snapshots, the global preference, and a one-shot queued-ID set, return `restartNow`, `keepQueued`, and `removeFromQueue`. Cover stopped, starting, online with/without active thread, working, error, equal versions, unknown versions, and already-restarting snapshots. Assert that only `.online` + no active thread + installed newer than running is immediately eligible.

- [x] **Step 4: Write failing aggregate notification tests**

Add a pure policy that accepts latest/installed state, affected runner counts, update-notification preference, and persisted last-notified versions. It returns at most one update-available event per latest version and at most one restart-required event per installed version/batch. Cover many profiles sharing one executable, many profiles/executables, disabled notifications, automatic idle-restart wording, and relaunch with the same persisted ledger.

- [x] **Step 5: Implement the minimal models/stores/policies and run tests**

```sh
swift test --filter 'AmpUpdatePreferencesStoreTests|AmpProfileUpdateStateTests|AmpIdleRestartPolicyTests|AmpUpdateNotificationPolicyTests'
```

- [x] **Step 6: Commit**

Commit as `feat(updates): model preferences and restart policy`.

---

### Task 3: Add an app test target and bounded command executor

**Files:**
- Modify: `project.yml`
- Modify: `AmpRunner.xcodeproj/project.pbxproj` (generated)
- Create: `App/Updates/AmpCommandExecutor.swift`
- Create: `Tests/AmpRunnerAppTests/AmpCommandExecutorTests.swift`

**Interfaces:**
- Produces: one non-shell subprocess executor used only by central Amp update work
- Consumes: executable URL, arguments, environment, timeout, and output byte limit

- [x] **Step 1: Add the Xcode unit-test target**

Add `AmpRunnerTests`, sourcing `Tests/AmpRunnerAppTests`, with `hostApplication: AmpRunner`, and depending on the local `AmpRunnerCore` product. Add it to the `AmpRunner` scheme test action. Run `Scripts/generate_project.sh` and inspect the generated project diff.

- [x] **Step 2: Write failing executor tests using temporary fixture executables**

Create executable shell fixtures only in each test's temporary directory. Verify separate arguments without shell interpretation, supplied environment, independent stdout/stderr, nonzero status, timeout termination, and bounded retained output.

- [x] **Step 3: Implement the bounded executor**

Use a request/result boundary:

```swift
struct AmpCommandRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let outputLimit: Int
}

struct AmpCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}
```

Use `Process` directly, asynchronously drain both pipes to avoid deadlock, cap retained bytes while continuing to drain excess output, and terminate on timeout/cancellation. Do not publish or persist process output here.

- [x] **Step 4: Run focused tests and commit**

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/AmpCommandExecutorTests
```

Commit as `test(app): add bounded Amp command execution`.

---

### Task 4: Implement the central update controller

**Files:**
- Create: `App/Updates/AmpUpdateController.swift`
- Test: `Tests/AmpRunnerAppTests/AmpUpdateControllerTests.swift`

**Interfaces:**
- Produces: one release schedule, registered executable state, deduplicated version probes, and deduplicated installations
- Consumes: `AmpCommandExecutor`, `URLSession`, file identity, and `AmpRunnerCore` parsing contracts

- [x] **Step 1: Define small injectable production dependencies**

Keep the observable controller app-facing while making latest fetch, command execution, sleep/clock, and executable-identity reads replaceable in tests. Publish `latestVersion`, `lastCheckedAt`, check state, installed versions by standardized path, install states by path, and one last completed install batch. Store only small values and bounded failure messages.

- [x] **Step 2: Write failing release schedule/check tests**

Verify one schedule task, idempotent enabling, 3-second initial sleep, hourly subsequent sleep, cancellation when disabled, manual checks while disabled, one fetch regardless of registrations, prior latest preservation on failure, malformed response rejection, and error clearing on success. Production uses the exact endpoint, a 5-second timeout, and cache bypass.

- [x] **Step 3: Write failing registration/probe tests**

Verify standardized-path dedupe and concurrent probe coalescing. Parse observed `amp version` output. Retain modification date, size, and file/inode identity when available; re-probe once when identity changes or a new latest release appears. Probe failure is path-scoped, returns nil, and never blocks runner launch.

- [x] **Step 4: Write failing install tests**

Verify current probe before install, outdated-only selection, exact `update --porcelain`, duplicate-path dedupe, no post-update version probe, `no update needed` preserving the pre-install probe, failure preserving installed state, manual retries, and at most one automatic attempt per path/latest pair unless file identity changes. Install distinct paths sequentially and publish one batch result.

- [x] **Step 5: Implement controller operations**

Expose:

```swift
func synchronizeExecutables(_ registrations: [AmpExecutableRegistration])
func setAutomaticChecksEnabled(_ enabled: Bool)
func setAutomaticInstallEnabled(_ enabled: Bool)
func checkNow() async
func installedVersion(for executableURL: URL) async -> AmpVersion?
func installOutdatedExecutables(automatic: Bool = false) async
func cancel()
```

Automatic installation runs after a successful check only when configured by the coordinator.

- [x] **Step 6: Run focused tests and commit**

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/AmpUpdateControllerTests
```

Commit as `feat(updates): centralize release checks and installs`.

---

### Task 5: Capture the Amp version for every supervisor launch

**Files:**
- Modify: `App/ProcessSupervisor.swift`
- Modify: `App/RunnerCoordinator.swift`
- Modify: `Sources/AmpRunnerCore/RunnerStatus.swift`
- Test: `Tests/AmpRunnerAppTests/ProcessSupervisorVersionTests.swift`

**Interfaces:**
- Produces: `ProcessSupervisor.runningAmpVersion` for the exact current launch
- Consumes: a generic async version-provider closure backed by `AmpUpdateController`

- [x] **Step 1: Write failing supervisor launch tests**

Inject a generic provider rather than the controller itself:

```swift
typealias AmpVersionProvider = (
    ResolvedRunnerCommand,
    [String: String]
) async -> AmpVersion?
```

Test that Start captures one environment snapshot, asks for the version before spawning, publishes the returned version only after successful launch, and still launches with `nil` after probe failure. Test Stop during a pending probe cancels launch and leaves the runner stopped. Test repeated Start while probing does not create duplicate launches. Use temporary fixtures and an injectable monitor URL/launcher seam rather than the built app bundle.

- [x] **Step 2: Refactor start into cancellable probe and launch phases**

Add `@Published private(set) var runningAmpVersion: AmpVersion?` and one owned `launchTask`. Resolve/validate the command, capture environment once, set `.starting`, await the provider, then spawn with the same snapshots if the request remains current. Update `.starting` documentation to include preflight probing. Clear the running version on termination or launch failure.

Cancel pending launch/restart tasks from Stop, deletion through Stop, and app termination. Keep abnormal-exit retries on `start(resetRestartPolicy: false)` so they also use a fresh centrally deduplicated probe.

- [x] **Step 3: Make restart lifecycle explicit enough to prevent duplicates**

Track the existing stop-then-start task instead of leaving it unowned. Ensure repeated restart requests do not schedule multiple replacement processes and intentional restart still does not count as abnormal exit. Do not add update policy to the supervisor.

- [x] **Step 4: Wire the central provider in the coordinator**

Construct one controller in `RunnerCoordinator`. Inject a closure that calls `installedVersion(for:)` for the resolved executable. Synchronize distinct registrations after profile load/create/edit/delete and PATH-setting changes, using the same `runnerEnvironment()` conventions as launches. Subscribe once to controller changes and re-publish; do not copy controller maps into profiles/supervisors.

- [x] **Step 5: Run tests and commit**

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/ProcessSupervisorVersionTests
swift test
```

Commit as `feat(runners): capture Amp launch versions`.

---

### Task 6: Join update state to profiles and orchestrate installs/restarts

**Files:**
- Modify: `App/RunnerCoordinator.swift`
- Test: `Tests/AmpRunnerAppTests/RunnerUpdateOrchestrationTests.swift`

**Interfaces:**
- Produces: profile update state, install actions, one-shot idle queue, and bulk restarts
- Consumes: controller/supervisor state, Core policies, and persisted preferences

- [x] **Step 1: Write failing state-join tests**

Cover coordinator-facing methods:

```swift
func updateState(for profile: RunnerProfile) -> AmpProfileUpdateState
func installAvailableUpdate()
func restartToUpdate(_ profile: RunnerProfile)
func restartAllWhenIdle()
func restartAllNow()
```

Profiles sharing an executable must share installed/install state while retaining distinct running versions. A successful restart must clear restart required naturally when the new running version is published.

- [x] **Step 2: Write failing idle-restart orchestration tests**

Maintain only coordinator-level one-shot queued IDs and update restarts in flight. Test auto-restart off/on, immediate eligible online restarts, working runners waiting until online/no active thread, Restart All When Idle queue semantics, stopped runners remaining stopped, ineligible states, queue cleanup, one-profile Restart to Update, and confirmed Restart All Now behavior.

- [x] **Step 3: Load/save and apply preferences**

Load `AmpUpdatePreferencesStore`, falling back to approved defaults and exposing malformed persistence as nonfatal `loadError`. Save atomically, update the central schedule/auto-install setting, and re-evaluate idle policy. Turning scheduled checks off must preserve other choices and manual Check/Install.

- [x] **Step 4: Wire central state changes once**

Subscribe to completed install batches and existing supervisor changes. Re-evaluate restart state only from these subscriptions; do not poll. Automatic/manual install operates on all outdated distinct registrations and publishes one batch.

- [x] **Step 5: Run focused tests and commit**

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/RunnerUpdateOrchestrationTests
```

Commit as `feat(updates): orchestrate runner updates at idle`.

---

### Task 7: Add aggregate update notifications and actions

**Files:**
- Modify: `App/Notifications/RunnerNotifier.swift`
- Modify: `App/RunnerCoordinator.swift`
- Test: `Tests/AmpRunnerAppTests/RunnerUpdateNotificationTests.swift`

**Interfaces:**
- Produces: one update-available and one restart-required notification per version
- Consumes: Core notification policy, install batches, and aggregate runner counts

- [x] **Step 1: Add testable update notification construction**

Extend `RunnerNotificationAction` with `.installUpdate`, `.restartAllWhenIdle`, and `.openUpdates`. Add separate update-available/restart-required categories. Build content through an internal pure builder so tests assert title/body/category/actions without posting to the system center.

- [x] **Step 2: Write failing aggregate notification tests**

Verify one update notification across any profile count; Install Update routes to all outdated executables; one install batch yields one restart notification; body reports concise total/idle/working counts; automatic idle restart reports restarted/pending counts and omits redundant restart action; default/open action shows Updates; disabling update notifications does not affect lifecycle notifications/UI; persisted versions suppress duplicates after relaunch.

- [x] **Step 3: Implement delivery and dedupe persistence**

Reuse lazy authorization. Generalize posting so app-wide notifications need no fake profile ID. Persist only last update-available and restart-required versions in `UserDefaults`. Delivery must not control state.

- [x] **Step 4: Route actions centrally**

Handle actions in `RunnerCoordinator`: install, queue/restart all when idle, or set `.updates` and open Settings. Never inject thread messages or route update actions to Amp thread URLs.

- [x] **Step 5: Run focused tests and commit**

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/RunnerUpdateNotificationTests
```

Commit as `feat(notifications): aggregate Amp update actions`.

---

### Task 8: Build General and Updates settings panes

**Files:**
- Modify: `App/AmpRunnerApp.swift`
- Modify: `App/Views/MenuBarContentView.swift`
- Modify: `App/Views/ProfileListView.swift`
- Create: `App/Views/GeneralSettingsView.swift`
- Create: `App/Views/UpdateSettingsView.swift`

**Interfaces:**
- Produces: five toolbar panes and persistent per-runner update state/actions
- Consumes: coordinator bindings and derived profile/controller state

- [x] **Step 1: Expand the existing toolbar Settings window**

Change `SettingsPane` to `.general`, `.runners`, `.environment`, `.updates`, `.logs`. Keep `TabView`; do not introduce a sidebar. Rename user-facing Profiles wording to Runners while retaining model names internally. Order panes General, Runners, Environment, Updates, Logs.

- [x] **Step 2: Move long-lived preferences into General**

Move **Start Amp Runner at Login** and **Notify on Thread Start / Finish / Failure**, including the login-item approval warning, from the menu to `GeneralSettingsView`. Leave menu operations and Settings links.

- [x] **Step 3: Add the Updates pane**

Show the four preferences with automatic install/restart visually subordinate to automatic checks without erasing/overwriting saved values. Show latest, last check, bounded errors, and installed versions grouped by standardized path. Provide Check Now, Install Now, Restart All When Idle, and Restart All Now….

Before Restart All Now, confirm whenever an affected runner is working and state that active work may be interrupted. This explicit confirmed action is the only bulk path allowed to interrupt work.

- [x] **Step 4: Add persistent runner version/update UI**

Every Runners row and profile submenu shows concise text: `Amp <running version>`, stopped `Amp <installed version>`, `Update available: <latest>`, `Restart required for <installed>`, or `Amp version unknown`. Add Restart to Update only for running restart-required profiles. Do not replace/recolor runner health.

- [x] **Step 5: Keep top-level restart messaging aggregate**

Add Updates… to open the pane. If runners need restart, use concise aggregate wording such as `Updates… — 6 runners need restart`; do not add one top-level item per profile.

- [x] **Step 6: Build and manually inspect both app variants**

```sh
xcodebuild -project AmpRunner.xcodeproj -scheme AmpRunner \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AmpRunner.xcodeproj -scheme AmpRunner-AppStore \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Check pane order, moved toggles, disabled automatic checks with manual actions intact, aggregate presentation with many profiles, no automatic working interruption, Restart All Now confirmation, and sensible path/version truncation.

- [x] **Step 7: Commit**

Commit as `feat(settings): surface Amp update management`.

---

### Task 9: Document behavior and run full verification

**Files:**
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`
- Modify: `docs/superpowers/plans/2026-08-22-amp-update-management.md` (check completed steps only)

**Interfaces:**
- Produces: documentation matching verified behavior
- Consumes: final implementation

- [x] **Step 1: Update user documentation**

Document five panes, four defaults, version display, aggregate notifications, install/restart actions, and Restart All Now confirmation. Explain that headless Amp omits interactive update checks and Amp Runner invokes Amp's updater instead of replacing the binary itself.

- [x] **Step 2: Update architecture documentation**

Document one controller/schedule, standardized executable keys, generic launch-version provider, coordinator-only joining/policy, porcelain as the installation/migration boundary, and separate update/runner health. Add update preferences and notification ledgers to persisted non-secret configuration.

- [x] **Step 3: Run all automated verification**

```sh
swift test
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild -project AmpRunner.xcodeproj -scheme AmpRunner-AppStore \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Do not report success if a command fails. Diagnose implementation failures and report unrelated pre-existing failures separately.

- [x] **Step 4: Perform a safe end-to-end fixture check**

Use a temporary fake Amp through injected dependencies, never `/Users/rgibbons/.amp/bin/amp`. Verify check → available → porcelain install → one restart-required state/notification → idle restart → new running version, with one release request, one install per distinct path, and no restart while working.

- [x] **Step 5: Review the final diff against the design**

Confirm no per-profile timers/watchers or copied controller maps; no thread-message injection; no downloader/checksum implementation; no post-`updated` probe; no automatic working interruption; one aggregate notification; bounded output/errors; and unchanged unrelated menu/status/security behavior.

- [x] **Step 6: Commit documentation and verification updates**

Commit as `docs(updates): explain Amp update management`.
