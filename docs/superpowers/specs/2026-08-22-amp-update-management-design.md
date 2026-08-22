# Amp Update Management Design

## Summary

Amp Runner will record the Amp version used to start each runner, check Amp's
official release endpoint centrally, optionally install updates through Amp's own
machine-readable updater, and keep a persistent restart-required state until each
running runner uses the installed version.

Update management is app-wide. It does not add polling loops or copied update state
to each `ProcessSupervisor`, and it never writes messages into Amp threads.

## Motivation and verified Amp behavior

Inspection of the installed Amp binary established these contracts:

- Interactive Amp starts an update service after three seconds and checks hourly.
- `amp --no-tui` uses a separate code path that does not create that service. A
  runner-only installation therefore does not discover or install releases.
- Binary installations check
  `https://static.ampcode.com/cli/cli-version.txt` with a five-second timeout and
  compare the returned version with the running version.
- Amp owns installation through `amp update`. Its `--porcelain` option prints exactly
  `updated <version>` or `no update needed` to stdout on success.
- Amp verifies the downloaded binary's SHA-256 checksum and only reports success after
  replacing the executable. Amp Runner does not need a second post-install
  `amp version` smoke test.

Amp Runner will mirror the check cadence and endpoint while retaining Amp's updater
as the compatibility boundary for downloads, package-manager behavior, migrations,
and future installation changes.

## Goals

- Show the Amp version on which each runner process started.
- Discover new Amp releases on machines that only run `amp --no-tui`.
- Let users control automatic checks, update notifications, automatic installation,
  and idle restarts independently.
- Install exclusively through the profile's configured Amp executable using
  `update --porcelain`.
- Aggregate notifications so a machine with many profiles is not flooded.
- Never interrupt a working runner automatically.
- Keep update work centralized and deduplicated by executable path.

## Non-goals

- Injecting update or restart messages into Amp thread history.
- Reimplementing Amp's downloader, checksum validation, package-manager detection, or
  migrations.
- Automatically stopping a working runner.
- Updating stopped runners as processes; they naturally use the installed version on
  their next start.
- Replacing the existing settings window with a sidebar or introducing a separate
  updater helper process.

## Preferences

The app stores four global, non-secret preferences in `UserDefaults`:

| Preference | Default | Behavior |
| --- | --- | --- |
| Automatically check for updates | On | Check after launch and hourly. Manual **Check Now** remains available when off. |
| Notify when updates are available | On | Allow update-related macOS notifications. Persistent in-app state is always shown. |
| Automatically install updates | Off | Run Amp's updater after discovering a newer release. Manual **Install Now** remains available when off. |
| Restart updated runners when idle | Off | Restart idle outdated runners and queue working outdated runners until they become idle. |

The automatic install and restart controls are visually subordinate to automatic
checks. Turning checks off stops scheduled work but does not erase the other saved
choices or prevent manual checks and installs.

## Architecture and ownership

```text
┌──────────────────────┐
│ Amp Release Endpoint │
└──────────┬───────────┘
           │ one app-wide schedule
           ▼
┌──────────────────────┐
│ AmpUpdateController  │
│ release/install state│
└──────────┬───────────┘
           │ published state
           ▼
┌──────────────────────┐
│ RunnerCoordinator    │
│ profile mapping      │
│ notification policy  │
│ idle restart policy  │
└──────────┬───────────┘
           │ lifecycle commands
           ▼
┌──────────────────────┐
│ ProcessSupervisor(s) │
│ running version      │
│ process/thread state │
└──────────────────────┘
```

### `AmpUpdateController`

One `@MainActor` observable controller owns update checks and installations. It:

- schedules one check three seconds after app launch and then hourly;
- performs manual checks on demand;
- publishes the latest release, last-check date, check/install progress, and errors;
- tracks the known installed version for each standardized executable path;
- deduplicates version probes and installations for profiles sharing an executable;
- invokes executables directly with `Process`, never through a shell;
- exposes no profile, thread, or restart concepts.

The controller uses a small Foundation-only value model for version parsing,
comparison, update state, and porcelain output parsing. Those contracts live in
`AmpRunnerCore` so they can be unit tested without AppKit.

### `ProcessSupervisor`

The supervisor remains responsible for one process. It gains only a published
`runningAmpVersion` value captured for the specific launch. It does not know about
release endpoints, update preferences, installation, or notifications.

Before launching `amp --no-tui`, the coordinator asks the update controller for a
deduplicated executable-version probe and passes the result into the supervisor's
start operation. Failure to read a version does not block runner startup; the UI
displays **Version unknown**. A successful restart captures the new version and clears
restart-required state through normal derived state, not an explicit reset.

### `RunnerCoordinator`

The coordinator joins app-wide update state to profiles and supervisors. It derives a
profile's display state from:

- the latest published version;
- the known installed version for the profile's standardized executable path; and
- the supervisor's running version, when running.

The coordinator subscribes once to the update controller and already subscribes to
supervisor changes. No supervisor timer or copied update model is introduced.

The coordinator also owns notification deduplication, one-shot restart queues, and
the global automatic idle-restart policy because those decisions span profiles.

## Release checking and executable probes

Automatic checking matches Amp's binary updater:

1. Wait three seconds after launch.
2. Fetch `https://static.ampcode.com/cli/cli-version.txt` with a five-second timeout
   and cache bypass.
3. Trim and validate the response as an Amp version.
4. Publish the latest version and check time.
5. Repeat hourly while automatic checks remain enabled.

There is only one network request per check cycle, regardless of profile count.

Installed versions are probed once per distinct executable when first needed. A
lightweight file identity snapshot is retained per standardized path. A changed file
identity or a newly observed latest release permits one deduplicated `amp version`
probe. The hourly cycle is the fallback for externally installed updates; there is no
per-profile file watcher or timer.

Version comparison mirrors Amp: compare numeric dot-separated components first, then
the optional prerelease label. Unknown or malformed versions produce an explicit
unknown/error state rather than guessing.

## Installation

Installation is manual unless **Automatically install updates** is enabled. Each
distinct configured executable is installed once even when many profiles use it.
Manual or notification installation actions install every configured executable that
is known to be behind the selected release.

Before installation, the controller ensures it has a current executable-version
probe. It then runs:

```text
<configured-amp-executable> update --porcelain
```

The runner environment snapshot supplies the same PATH and environment conventions
used for runner launches. stdout and stderr are bounded in memory.

The result contract is:

- Exit zero and `updated <version>`: record that version as installed.
- Exit zero and `no update needed`: preserve the immediately preceding probed
  installed version.
- Nonzero exit, timeout, or any other stdout: publish an installation error and do not
  change the installed version.

Only exact trimmed porcelain output is accepted. Human-readable stderr may be shown
in the Updates pane on failure but is never parsed as state.

Amp Runner does not invoke `amp version` after `updated <version>`. The porcelain
version and successful exit are Amp's installation contract, and Amp already verifies
the downloaded artifact.

## Per-profile derived states

Each profile displays one derived state:

- **Version unknown**: no running or installed version could be read.
- **Up to date**: the running/installed version is at least the latest known release.
- **Update available**: the latest release is newer than the installed executable.
- **Installing**: the shared executable is being updated.
- **Restart required**: the installed executable is newer than the running process.
- **Update failed**: the shared executable's most recent install failed.

Runner health (`Stopped`, `Starting`, `Online`, `Working`, or `Error`) remains separate
and authoritative. Update state does not turn a healthy runner into an error or alter
the aggregate menu-bar health icon.

## Idle restart policy

A runner is eligible for an automatic or queued restart only when all are true:

- it is running an older version than the installed executable;
- its status is `.online`;
- it has no active thread; and
- it is not already stopping or restarting.

Working and starting runners are never interrupted automatically. When a working
runner returns to online/idle, the coordinator re-evaluates the policy and restarts it
if either the global preference is enabled or the profile is in the one-shot restart
queue.

The **Restart All When Idle** action:

- restarts currently eligible runners immediately;
- queues working outdated runners for one restart when they become idle;
- leaves stopped runners stopped; and
- removes each profile from the queue after restart or when it no longer needs one.

The Updates pane also offers **Restart All Now…**. If any affected runner is working,
Amp Runner presents a confirmation explaining that active work may be interrupted.
This explicit action is the only bulk path allowed to restart working runners.

## Notifications

Update notifications use a separate preference from thread lifecycle notifications
but share the existing notification authorization infrastructure.

Notifications are app-wide and deduplicated by release version:

1. **Update available**: one notification when a newly observed version is newer than
   at least one configured executable. **Install Update** updates every configured
   outdated executable; **Open Amp Runner** shows the executable groups and affected
   profiles before the user acts.
2. **Restart required**: one notification after an installation, regardless of profile
   count. Its body summarizes affected runners, for example:
   `6 running runners need to restart. 4 are idle and 2 are working.`

When automatic idle restart is off, the restart notification offers:

- **Restart All When Idle**
- **Open Amp Runner**

When automatic idle restart is on, eligible runners restart immediately and working
runners are queued. The notification instead summarizes completed and pending
restarts, for example:
`4 runners restarted. 2 working runners will restart when idle.` It only needs **Open
Amp Runner**.

Notification delivery never controls state. Disabling notifications or denying macOS
authorization leaves all persistent UI and actions intact.

## Settings and persistent UI

The existing toolbar-style settings window remains appropriate. It expands to five
panes rather than introducing a sidebar:

1. **General**: launch at login and thread lifecycle notifications.
2. **Runners**: renamed from Profiles; existing profile management plus version/update
   state.
3. **Environment**: existing PATH controls.
4. **Updates**: the four preferences, latest release, last check, errors, and installed
   versions grouped by executable path, plus **Check Now**, **Install Now**, **Restart
   All When Idle**, and **Restart All Now…**.
5. **Logs**: existing log viewer.

Long-lived preference toggles move from the menu into Settings. The menu remains
focused on operations.

Every profile submenu and Runners row persistently shows:

- `Amp <running version>` during normal operation;
- `Update available: <latest version>` before installation;
- `Restart required for <installed version>` after installation; and
- **Restart to Update** when a running profile is outdated.

Stopped profiles show their installed version and update availability, but never show
restart required.

## Error handling

- Release-check failures preserve the last successful latest version and display a
  nonfatal check error with the failure time.
- Version-probe failures affect only profiles using that executable and do not block
  runner launch.
- Installation failures preserve running and installed version state, expose bounded
  stderr, and may be retried manually.
- Cancellation or app termination stops scheduled checks and child update/version
  processes where practical; it never kills runner processes through update cleanup.
- A malformed endpoint response or malformed porcelain output is treated as an error,
  not as an available or installed version.

## Testing

Foundation-only unit tests cover:

- Amp version parsing and comparison, including prerelease labels;
- release-response validation;
- exact porcelain output parsing;
- profile update-state derivation;
- preference defaults and persistence;
- deduplication by standardized executable path; and
- idle-restart decisions for stopped, starting, online, working, and error states.

App-level tests or injected fakes cover:

- one central schedule rather than per-profile polling;
- check and install transitions;
- aggregate notification counts and version deduplication;
- automatic and one-shot idle restart queues;
- no interruption of working runners; and
- clearing restart-required state after a successful restart.

Verification includes `swift test`, an Xcode build for the macOS app targets, and
manual UI checks for settings dependencies, aggregated notification wording, and
runner menu states.
