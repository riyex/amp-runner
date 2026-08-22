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
