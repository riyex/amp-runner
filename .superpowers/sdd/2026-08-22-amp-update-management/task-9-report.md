# Task 9 Report: Documentation and Full Verification

## Outcome

Complete. README and architecture documentation now describe verified update behavior, the plan is checked through Task 9, and a hosted fake-Amp orchestration fixture covers the controller-to-coordinator update/restart flow without reading or modifying `/Users/rgibbons/.amp/bin/amp` or real application preferences.

## Documentation

- `README.md`: documents the five Settings panes; four preference defaults; running/stopped version presentation; aggregate notifications; manual install and restart actions; idle-only automatic behavior; and Restart All Now confirmation. It also explains that headless Amp omits the interactive update check and Amp Runner delegates installation to `amp update --porcelain` rather than replacing binaries.
- `ARCHITECTURE.md`: documents the single controller/schedule, standardized path keys, generic launch-version provider, coordinator-only joining/policy, porcelain migration boundary, the absence of downloader/checksum code, bounded controller/published state, separate update/runner health, and persisted non-secret update preferences/notification ledgers.
- `docs/superpowers/plans/2026-08-22-amp-update-management.md`: committed the previously untracked plan and checked only completed Task 9 steps.

## Safe integrated fixture

`RunnerUpdateOrchestrationTests.testFakeAmpEndToEndCheckInstallNotificationAndIdleRestart` creates an executable shell fixture and version/call-ledger files under a unique temporary directory. The production bounded command executor invokes that fixture directly through an injected `AmpUpdateController`. The coordinator consumes the controller's real `$lastCompletedInstallBatch` publication; only release fetching, deterministic supervisor snapshots/events, restart recording, notification delivery, and preferences are injected. Temporary roots are removed and every fixture-owned `UserDefaults` persistent domain is deleted during teardown.

The fixture proves: one release request → `1.0.0` update available → one `update --porcelain` for two syntactically distinct paths that standardize to the same executable → controller publication drives installed `2.0.0`, exactly one aggregate restart-required notification, and restart orchestration → no restart while Working → one restart after an injected Online/idle supervisor event → injected running `2.0.0` and Up to Date. It never launches a real runner or resolves or invokes the real Amp path.

## Exact verification

- `swift test` — exit 0; 150 XCTest tests executed, 0 failures; Swift Testing reported 0 additional tests.
- `xcodebuild test -project AmpRunner.xcodeproj -scheme AmpRunner -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — exit 0, `** TEST SUCCEEDED **`; 58 tests executed, 0 failures. Includes the integrated fake-Amp fixture.
- `xcodebuild -project AmpRunner.xcodeproj -scheme AmpRunner-AppStore -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` — exit 0, `** BUILD SUCCEEDED **`. The distinct App Store product name allowed the exact command to succeed in reused DerivedData.
- `git diff --check` — exit 0, no output.

Xcode emitted expected hosted-test diagnostics about App Intents/LaunchAgent/bookmark services and an architecture destination warning; none were build or test failures.

## Deferred-minor triage

- Pipe read errors sharing EOF cleanup: remains deferred; output is bounded and full verification passed.
- Controller cache cleanup: unregistration prunes all executable-keyed published/private maps while a bounded scalar generation source keeps stale in-flight results invalid across remove/re-add cycles.
- `cancel()` not owning caller-created manual operation tasks: scheduled/probe/install work is canceled; no polling or verification blocker.
- Missing exact concurrent latest-release-during-probe case: token/release coverage and full suite passed; remains a narrow test gap.
- Fixture cleanup: all temporary fixture roots are removed, and every suite-scoped `UserDefaults` persistent domain is deleted.
- Reused DerivedData duplicate-product risk: resolved by the previously implemented distinct `AmpRunner-AppStore.app` product; the exact required build passed in reused DerivedData.
- Native monitor one-time load flake: did not reproduce; all 150 SwiftPM tests passed.
- Regressed endpoint values potentially treated as new notification versions: remains deferred and does not introduce polling or unbounded state.
- System notification authorization coverage: hosted builders and injected defaults cover policy; real-center integration remains intentionally outside safe verification.

No deferred item required a load-bearing fix for full verification or the low-memory/no-polling requirements.

## Final invariant review

Reviewed the complete branch diff from the merge base (39 tracked files before this report, 5,551 insertions/62 deletions at review time) and searched the update implementation/tests/docs for timers, watchers, downloads/checksums, thread-message paths, updater invocation, output limits, and working-runner restart paths.

- One app-wide schedule task; no per-profile/supervisor timer, polling loop, or file watcher.
- Controller state remains centralized; profiles/supervisors do not copy controller maps.
- Update actions route centrally and do not inject Amp thread messages.
- No downloader/checksum implementation; only direct `<configured executable> update --porcelain`.
- `updated <version>` updates controller state without a post-update version probe.
- Automatic/queued restart only selects Online runners without active work; only confirmed Restart All Now includes Working runners. Stopped runners remain stopped.
- Notification policy/builders aggregate update and restart-required events; the fixture observes exactly one restart-required notification.
- Command stdout/stderr are capped per stream while drained, controller command limits are 64 KiB, and displayed errors are capped at 512 characters.
- Existing menu status precedence/colors, lifecycle notifications, credential/security boundaries, and macOS 14/menu-bar architecture remain unchanged.

## Commit

- `docs(updates): explain Amp update management` — documentation, integrated fake-Amp verification fixture, completed plan ledger, and this report.

## Concerns

Only the deferred minor items above. Verification used test-only temporary executables and isolated preferences; no real updater or user/app settings were touched.
