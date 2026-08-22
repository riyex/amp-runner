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
