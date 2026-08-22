# Task 6 Report: Update orchestration

## Outcome

Implemented the coordinator-owned profile/update join, preference persistence and application, manual install trigger, automatic and explicit idle queues, confirmed bulk restarts, queue cleanup, and restart-in-flight lifecycle tracking. Shared executable state remains centralized in `AmpUpdateController`; per-profile running state remains in each `ProcessSupervisor`.

## TDD evidence

- RED: focused Xcode test initially failed to compile because the new coordinator APIs and seams did not exist. The first scheme invocation also exposed the pre-existing App Store product-name collision; `PRODUCT_NAME` is now distinct.
- RED lifecycle regression:
  `xcodebuild test ... -only-testing:AmpRunnerTests/RunnerUpdateOrchestrationTests/testPublishedNewRunningVersionClearsInFlightAndRestartRequirement`
  failed at the transient stopped-state assertion, proving in-flight state was being cleared too early.
- GREEN:
  `xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner -destination 'platform=macOS' -derivedDataPath /tmp/AmpRunnerTask6Derived CODE_SIGNING_ALLOWED=NO -only-testing:AmpRunnerTests/RunnerUpdateOrchestrationTests`
  passed 7/7 tests.

## Files

- `App/RunnerCoordinator.swift`
- `Tests/AmpRunnerAppTests/RunnerUpdateOrchestrationTests.swift`
- `project.yml`
- `AmpRunner.xcodeproj/project.pbxproj` (regenerated)

## Full suite

- `swift test`: 149 tests passed, 0 failures on the final run.
- The immediately preceding run had one transient process-monitor timing failure (`testNativeMonitorTerminatesChildWhenWatchedParentExits`); an unchanged rerun passed all 149 tests.

## Self-review

- Combine callbacks are main-actor confined. Real supervisor `objectWillChange` is deferred one actor turn because Combine publishes before mutation; injected deterministic publishers remain synchronous.
- Restart IDs are inserted before invoking restart callbacks, preventing callback/reentrancy duplicates.
- In-flight IDs survive transient stopped/starting relaunch states and clear only after a published running version reaches the installed version.
- Idle policy only restarts online runners without active threads; working runners remain queued, while stopped/starting/error entries are removed. Explicit `restartAllNow()` may interrupt working runners because it is already confirmed, but never starts stopped runners.
- Coordinator reads controller state centrally by executable path and does not poll or copy controller maps per profile.

## Concerns

- Hosted Xcode tests emit benign system-service/LaunchAgent diagnostics in the test host.
- The process-monitor full-suite test demonstrated an existing timing flake once; the required clean rerun passed.
