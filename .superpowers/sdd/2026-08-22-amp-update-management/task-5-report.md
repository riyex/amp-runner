# Task 5 Report: Capture the Amp version for every supervisor launch

## Outcome

- `ProcessSupervisor` now captures one command/environment snapshot, enters `.starting`, probes through a generic async provider, and only publishes `runningAmpVersion` after that exact process successfully spawns.
- Probe failure returns `nil` and never blocks launch. Stop, termination, and launch failure clear the version.
- Pending launches and delayed/intentional restarts are owned tasks. Stop/app termination cancel pending work; duplicate starts during preflight are ignored; abnormal retries return through the same probe path.
- `RunnerCoordinator` owns one `AmpUpdateController`, forwards its changes, injects the central provider, and resynchronizes standardized executable registrations on load, save/create/edit, delete, and PATH settings changes.

## TDD Evidence

### RED

Command:

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/ProcessSupervisorVersionTests
```

Expected failure captured before implementation: the new tests did not compile because `ProcessSupervisor` lacked `versionProvider`, injectable `monitorExecutableURL`, and `runningAmpVersion`.

### GREEN

Same focused command: **TEST SUCCEEDED**. Executed 4 tests with 0 failures:

- successful probe and exact environment snapshot
- failed probe still launches with no version
- stop during pending probe cancels launch
- repeated start during probe creates one probe/launch

## Full Suite

```sh
swift test
```

**Passed:** 149 tests, 0 failures.

## Files

- `App/ProcessSupervisor.swift`
- `App/RunnerCoordinator.swift`
- `App/Updates/AmpUpdateController.swift`
- `Sources/AmpRunnerCore/RunnerStatus.swift`
- `Tests/AmpRunnerAppTests/ProcessSupervisorVersionTests.swift`
- `AmpRunner.xcodeproj/project.pbxproj`

## Self-review

- Start/stop: cancellation is checked after an uncooperative provider returns, so stopped preflights cannot spawn later.
- Start/start: `launchTask` guards the entire preflight, preventing duplicate probes and processes.
- Stop/restart: stop cancels both launch and restart tasks; intentional restarts remain distinguishable from abnormal exits.
- Termination/retry: process state and version clear before abnormal retry scheduling; retries call the same `start(resetRestartPolicy: false)` preflight.
- Process ownership: the version is assigned only after `Process.run()` succeeds and is cleared by every failure/termination path.
- Coordinator lifecycle: app termination and stop-all now stop pending preflights as well as running processes.

## Concerns

- Focused hosted tests emit existing macOS service/bookmark diagnostics from the app test host; they do not affect test results.
- No update preferences, scheduling, or update orchestration were added; those remain for Task 6.

## Fix Round 1

### Outcome

- Process and pipe callbacks now carry the originating `Process` identity. A stale termination callback disables only its captured old pipe handlers, then returns without clearing or changing the replacement launch's process, pipes, command, environment, version, status, retry policy, or restart work.
- Added deterministic termination-delivery and restart-policy seams used only to force stale ordering and zero-delay retries in tests.
- Added coverage for repeated intentional restart, stale termination ordering, abnormal retry through the same version provider without policy reset, post-probe launch failure, and coordinator load/edit/delete/PATH registration synchronization.

### RED evidence

Focused Xcode invocation initially failed to compile because `ProcessSupervisor` did not accept `terminationCallbackScheduler` or an injected `restartPolicy`. After adding the seams, the repeated intentional restart test also failed with `XCTAssertEqual: 1 is not equal to 2`, exposing an assertion that observed the old `.starting` state rather than waiting for the replacement probe; the test was corrected to synchronize on provider entry.

### GREEN evidence

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/ProcessSupervisorVersionTests \
  -only-testing:AmpRunnerTests/RunnerCoordinatorUpdateRegistrationTests
```

`TEST SUCCEEDED`: 9 tests, 0 failures (8 supervisor lifecycle/version tests and 1 coordinator registration test).

```sh
swift test
```

Passed 149 tests with 0 failures. `git diff --check` also passed.

### Race self-review

- Old termination after replacement spawn: identity guard prevents all current-launch mutation; only captured old readability handlers are detached.
- Old readability delivery after replacement spawn: each delivery checks the captured process is still the supervisor's current process before ingesting bytes.
- Repeated intentional restart: one replacement provider call is observed and intentional stop does not consume abnormal retry budget.
- Consecutive abnormal exits: three provider calls exhaust an injected two-retry policy, proving retries use the same provider path and do not reset policy.
- Probe success followed by spawn rejection: version remains unpublished and no process is retained.

### Remaining concern

- Hosted Xcode tests continue to emit pre-existing macOS service/bookmark diagnostics; all selected tests pass. The Low fixture-cleanup item remains deferred as requested.

## Fix Round 2

### Outcome

- The post-probe launch-failure test now blocks inside the provider, verifies `.starting` with no published version, then completes the provider before allowing the missing-monitor spawn rejection. This deterministically proves provider entry/completion precedes launch failure and the probed version is never published.
- Executable registrations now retain the coordinator's current runner environment. PATH-save coverage verifies the refreshed registration starts with the newly saved directory; automatic probes and updates consume that same registered environment.
- A new lifecycle test performs intentional replacements before switching the fixture to abnormal exits. It observes the replacement plus the full two-retry abnormal budget (five provider calls total), proving intentional restart does not consume an abnormal retry attempt.

### RED evidence

- The initial pre-seam focused invocation was blocked before Swift compilation by the project's duplicate `AmpRunner.app` product-output error, so it did not provide a valid test RED. Code inspection confirmed registrations carried only the unchanged URL, and the new PATH assertion required the narrow `registeredEnvironment(for:)` controller surface.
- After introducing environment-backed registrations, the focused hosted test crashed on duplicate executable registrations. This exposed a real deduplication gap in the initial implementation; synchronization was corrected to preserve the first environment for each standardized executable path.
- A reused DerivedData directory intermittently produced the project's known duplicate-product build error. A fresh DerivedData directory gave the authoritative focused result below.

### GREEN evidence

```sh
xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner \
  -derivedDataPath /tmp/amp-runner-task5-r2-green \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:AmpRunnerTests/ProcessSupervisorVersionTests \
  -only-testing:AmpRunnerTests/RunnerCoordinatorUpdateRegistrationTests
```

`TEST SUCCEEDED`: 10 tests, 0 failures (9 supervisor tests and 1 coordinator registration test).

```sh
swift test
```

Passed 149 tests with 0 failures. `git diff --check` also passed.

### Remaining concern

- Hosted Xcode tests still emit the pre-existing macOS service/bookmark diagnostics. Reusing DerivedData can also trigger duplicate `AmpRunner.app` product output; a clean/fresh DerivedData path succeeds. The deferred Low fixture cleanup was not revisited.

## Fix Round 3

### Outcome

- Probe flights, successful probe cache entries, and automatic-attempt deduplication now include the command environment. Registration environment changes cancel the old flight and invalidate its matching metadata before subsequent central work.
- Completion publication remains token-guarded: an uncooperative canceled probe can return to its original caller but cannot overwrite the refreshed probe's published state.
- The coordinator test now saves PATH settings while an old central probe is pending, starts replacement central work, and asserts the resulting `AmpCommandRequest.environment["PATH"]` begins with the newly resolved directory. The replacement publishes `2.0.0`; the late old completion cannot replace it.
- Standardized-path deduplication still chooses the first registration environment deterministically, and first registration does not trigger spurious invalidation.

### TDD and verification evidence

- The behavioral test was written first. Its initial focused invocation was blocked before Swift compilation by the known duplicate `AmpRunner.app` product-output error. A temporary, uncommitted distinct App Store product name allowed authoritative hosted testing; that temporary project setting was removed afterward.
- Focused controller/supervisor/registration tests: `TEST SUCCEEDED`, 22 tests, 0 failures (12 controller, 9 supervisor, 1 coordinator registration).
- Full `swift test`: 149 tests, 0 failures.
- `git diff --check`: passed.

### Self-review

- Environment cache matching: both in-flight reuse and successful cached-version reuse require exact environment equality; automatic update attempt dedupe does too.
- Registration synchronization: environments are collected with standardized path keys and first-registration wins before changes are compared, preserving deterministic shared-path behavior.
- Stale completion: changed-environment flights are canceled and removed; replacement flights receive new tokens, so old completions fail the token guard and cannot publish versions or errors.

### Remaining concern

- The checked-in project still has the pre-existing duplicate `AmpRunner.app` output issue when both app targets share a product name. Hosted verification required the temporary test-only product-name workaround described above. Deferred Low fixture cleanup remains out of scope.
