# Restart on Abnormal Exit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restart AmpRunner and per-profile Amp monitor processes after abnormal exits without restarting on user-requested stops or parsed thread failures.

**Architecture:** A bundled launchd LaunchAgent handles app-level relaunch on non-zero exit. `ProcessSupervisor` handles per-profile monitor/Amp abnormal exits with a small pure Swift restart policy in `AmpRunnerCore` so retry limits are unit-testable.

**Tech Stack:** Swift 5.9, SwiftPM tests, SwiftUI app target, ServiceManagement, launchd property lists, XcodeGen.

## Global Constraints

- macOS deployment target remains `14.0`.
- Keep the app menu-bar-only and avoid per-profile launch agents.
- Do not restart on parsed `threadFailed` events unless the Amp process exits abnormally.
- Manual Stop, Restart, Quit, and profile deletion are intentional stops and must not auto-restart.
- Use bounded retries with delays `2s`, `5s`, and `15s`, then stop after three abnormal exits inside `60s`.
- Preserve the existing native monitor helper and do not add reconnect/adoption behavior.

---

### Task 1: Core Restart Policy

**Files:**
- Create: `Sources/AmpRunnerCore/RunnerRestartPolicy.swift`
- Test: `Tests/AmpRunnerCoreTests/RunnerRestartPolicyTests.swift`

**Interfaces:**
- Produces: `RunnerRestartPolicy`, `RunnerRestartDecision`
- Consumes: `Date`, `TimeInterval`

- [x] Write failing tests for first, second, and third abnormal exits returning `2`, `5`, and `15` second delays.
- [x] Write a failing test that the fourth abnormal exit inside `60s` returns `.stop(message:)`.
- [x] Write a failing test that failures older than `60s` are pruned.
- [x] Implement the minimal policy and run `swift test --filter RunnerRestartPolicyTests`.

### Task 2: Supervisor Auto-Restart

**Files:**
- Modify: `App/ProcessSupervisor.swift`

**Interfaces:**
- Consumes: `RunnerRestartPolicy`, `RunnerRestartDecision`
- Produces: automatic restart scheduling for abnormal monitor/Amp exits

- [x] Add restart state: policy, pending restart task, and intentional-stop flag.
- [x] Reset the restart policy on user-initiated starts and restarts.
- [x] Cancel pending restarts on Stop, app termination, and profile deletion through the existing `stop()` path.
- [x] On abnormal monitor termination or non-zero exit, append a log line, set an error status during backoff, then call `start()` without resetting the retry window.
- [x] Leave clean exits and parsed thread failures unchanged.

### Task 3: LaunchAgent Login Registration

**Files:**
- Create: `App/Resources/com.riyex.amprunner.agent.plist`
- Modify: `App/AmpRunnerApp.swift`
- Modify: `App/LaunchAtLoginManager.swift`
- Modify: `project.yml`
- Update docs if the behavior text changes materially.

**Interfaces:**
- Consumes: `SMAppService.agent(plistName:)`
- Produces: launchd-managed app startup with `KeepAlive` on unsuccessful exit

- [x] Add a bundled LaunchAgent plist with `BundleProgram = Contents/MacOS/AmpRunner`, `RunAtLoad = true`, and `KeepAlive.SuccessfulExit = false`.
- [x] Copy the plist into `Contents/Library/LaunchAgents` during app builds.
- [x] Update `LaunchAtLoginManager` to register/unregister the LaunchAgent service and migrate away from any previously registered `SMAppService.mainApp`.
- [x] Add a duplicate-instance guard so immediate LaunchAgent bootstrap does not create a second menu-bar app beside an already-running instance.
- [x] Use Xcode diagnostics/build to verify ServiceManagement code and project configuration.

### Task 4: Verification

**Files:**
- Existing source and project files

**Interfaces:**
- Consumes: SwiftPM and Xcode build systems
- Produces: verified compile/test result

- [x] Run `swift test`.
- [x] Run Xcode diagnostics for modified Swift files.
- [x] Build the `AmpRunner` scheme with Xcode.
- [x] Inspect the built `.app` bundle for `Contents/Library/LaunchAgents/com.riyex.amprunner.agent.plist`.
