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
