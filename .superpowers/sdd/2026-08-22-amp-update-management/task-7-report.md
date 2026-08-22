# Task 7 Report

## Outcome

Added aggregate update-available and restart-required notifications, persistent per-version dedupe, lazy system delivery, and centrally routed update actions.

## RED

After adding `RunnerUpdateNotificationTests`, the focused hosted build failed on the intentionally missing builder, request model, notifier seam, and update actions. The first generated-project run had executed zero tests, so the project was regenerated and RED was captured again with the new test file included.

## GREEN

- Focused hosted notification/orchestration tests: 17 passed, 0 failed.
- `swift test`: 149 passed, 0 failed.
- `git diff --check`: clean.

## Files

- `App/Notifications/RunnerNotifier.swift`
- `App/RunnerCoordinator.swift`
- `App/Views/MenuBarContentView.swift`
- `Tests/AmpRunnerAppTests/RunnerUpdateNotificationTests.swift`
- `Tests/AmpRunnerAppTests/RunnerUpdateOrchestrationTests.swift`
- `AmpRunner.xcodeproj/project.pbxproj`

## Self-review

- Counts dedupe executable paths while retaining affected profile counts.
- Release and installation notifications are each deduped by persisted version and are advanced before delivery, so denied delivery cannot control app state or prompt repeatedly.
- Installation completion emits at most one aggregate restart event regardless of profile count.
- Automatic idle restart content reports restarted/pending counts and uses a system category without the redundant restart action.
- Default/Open actions route to Updates; install and restart actions route to coordinator operations and never carry profile/thread metadata.
- Update notification preference remains independent of the existing lifecycle notification preference.

## Concerns

The Updates pane UI is scheduled for Task 8. Task 7 adds the `.updates` routing target now, so the action state is correct but the actual tab will appear when that pane is implemented.

## Fix Round 1

- Carried the completed `AmpInstallBatch` into notification orchestration and added a porcelain-authoritative outcome (`updated`, `noUpdateNeeded`, or `failed`) to each result.
- Restart aggregates now join profiles to only the standardized executable paths successfully updated by that batch. Empty, all-failed, and no-update batches cannot reuse unrelated restart state or versions.
- Aggregate counts include only idle `.online` runners without an active thread and `.working` runners; starting, error, and stopped runners are excluded.
- Added coverage for mixed outcomes, unrelated prior restart state, empty/failed/no-update batches, starting exclusion, automatic wording/actions, coordinator action effects, and porcelain outcomes.
- RED: focused hosted tests failed to compile because batch outcomes and batch-carrying completion publishers did not yet exist.
- GREEN: focused hosted notification/controller/orchestration tests passed (35 tests); `swift test` passed (149 tests); `git diff --check` passed.
- Self-review: notification identity remains the actual updated version, profile counts are path-joined from the completed batch, and one policy evaluation produces at most one aggregate restart notification. Porcelain remains authoritative with no post-install probe; notification preference and delivery state remain independent.
- Deferred as requested: version-regression dedupe and broader integration cleanup (Low findings).

## Fix Round 2

- Restart notification dedupe now uses the completed batch timestamp identity rather than the representative maximum version; the representative version remains display-only and no executable paths are persisted.
- Added mixed-version coverage proving a new batch still emits one aggregate notification when its maximum version was already notified, while repeated evaluation of that exact batch is suppressed.
- Added a narrow coordinator operation seam and proof that the `.installUpdate` notification action invokes installation of all outdated executables.
- RED: core tests rejected the missing batch identity API, and hosted tests rejected the missing coordinator installation seam.
- GREEN: focused hosted notification/orchestration tests passed; `swift test` passed 150 tests; `git diff --check` passed.
- Persistent dedupe remains advanced independently of delivery authorization/result, and update notifications remain aggregate and free of profile/thread metadata.

## Fix Round 3

- Added an immutable UUID identity to every `AmpInstallBatch`, with a default generated value and an injectable initializer value for deterministic tests.
- Restart-notification dedupe now persists and compares the batch UUID rather than deriving identity from `completedAt`; completion time remains unchanged for state/display use and no executable paths are persisted.
- Added coverage proving distinct IDs with the same completion timestamp both emit one aggregate notification, replaying the same batch ID is suppressed, and a persisted batch ID remains suppressed after notifier relaunch.
- Representative maximum installed version selection and aggregate notification content remain unchanged.
- RED: focused hosted tests failed to compile because `AmpInstallBatch` did not accept an ID.
- GREEN: focused hosted notification/orchestration tests passed; `swift test` passed 150 tests; `git diff --check` passed.
