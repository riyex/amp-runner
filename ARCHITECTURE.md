# Architecture

## 1. What this is

Amp Runner is a native macOS menu-bar-only supervisor for [Amp](https://ampcode.com)'s
headless runner mode. Amp already does all the work: `amp --no-tui` starts the CLI in
runner mode, where it connects back to ampcode.com and waits to accept and execute
threads that you create from the web or from your phone, running them in a local working
directory. What Amp does not give you is a way to see at a glance whether your runners
are up, to start and stop them without keeping terminal windows open, or to keep several
of them (one per repository) straight. Amp Runner is that front-end and nothing more — it
runs the user's own `amp` binary as a supervised child process, reads its output, and
shows status. It does not reimplement, wrap, proxy, or modify Amp's protocol, and if Amp
Runner is quit, everything it supervised can be reproduced by pasting the equivalent
terminal command it displays.

## 2. Core / UI split

The repository is deliberately split into a pure core, a small native monitor helper, and
the app shell.

| Layer | Location | Platforms | Verified by |
| --- | --- | --- | --- |
| `AmpRunnerCore` | `Sources/AmpRunnerCore/` | macOS; unverified Linux plumbing | `swift test` on macOS |
| `AmpRunnerMonitorSupport` / `AmpRunnerMonitor` | `Sources/AmpRunnerMonitorSupport/`, `Sources/AmpRunnerMonitor/` | macOS; unverified Linux plumbing | `swift test`, Xcode build on macOS |
| App shell | `App/` | macOS 14+ only | Xcode build |

`AmpRunnerCore` is a SwiftPM library that imports **Foundation and nothing else** — no
AppKit, SwiftUI, UserNotifications, or ServiceManagement. Its platform-neutral boundary
and the monitor's conditional Darwin/Glibc imports leave room for Linux support, but CI
tests macOS only. Everything that can be decided without a window lives there:

- `RunnerProfile` — the Codable configuration record, its default argument list, and
  field validation.
- `RunnerCommandBuilder` — pure translation of a profile into a `ResolvedRunnerCommand`
  (executable URL, argument list, working-directory URL) plus the one-line preview string.
- `RunnerStatus` / `RunnerEvent` — the state machine's vocabulary.
- `RunnerLogParser` — the heuristic log-line matcher table.
- `RunnerProfileStore` — JSON persistence behind an injectable `ProfileStoreFileIO`
  protocol, including the duplicate-working-directory rule.
- `RunnerPathSettings` — global ordered user directories and deterministic `PATH`
  resolution.
- `AmpSettingsChecker` — reads and merges `amp.remoteThreadCreation.enabled` from
  settings-file *contents* passed in as `Data`, never from a hardcoded path.

`AmpRunnerMonitor` is a tiny native command-line helper copied into
`AmpRunner.app/Contents/Helpers/`. It launches the resolved Amp command directly, mirrors
stdout/stderr back to the app's pipes, watches the app PID, and forwards SIGINT followed
by SIGTERM if the app disappears. It exists because a normal child process is reparented
when a parent app is killed by Xcode or crashes.

The Settings window has one global **Environment** tab, shared by all profiles. Its ordered
user directories are prepended to `PATH`; app-inherited entries follow, then existing
conventional developer and system directories. Resolution normalizes and stably
deduplicates entries. Missing absolute user directories remain in the setting and produce a
warning, while empty, relative, and colon-containing entries are invalid and are not saved.
The resolved `PATH` is captured when a profile starts or restarts, so changing the setting
does not alter a running process. That same launch snapshot is passed to the monitor helper
and Amp, and is retained for Amp metadata subprocesses.

Amp Runner directly launches its processes; it does not execute a login shell or source
shell startup files. It therefore does not promise complete Terminal-environment parity or
support arbitrary environment variables or secrets.

The point is testability. Because none of this touches a UI framework, the core and
monitor-support tests run from SwiftPM on macOS without opening Xcode, and the parts that
would otherwise be untestable — "what Amp command will we run?", "is this settings file
already enabled?", "do these two profiles collide?" — are covered by ordinary unit tests
rather than by clicking through the app.

The consequence for the UI layer is that it stays thin. `RunnerCoordinator` holds state
and routes actions, `ProcessSupervisor` owns one monitored process, and the SwiftUI views
render. None of them make decisions the core could have made. In particular, the
confirmation sheet summarizes the same `ResolvedRunnerCommand` value that is handed to
the launcher, so the Amp executable or arguments the user approves cannot drift from what
is run.

## 3. Distribution recommendation

**Ship Amp Runner with Developer ID signing + Hardened Runtime + notarization, distributed
directly — a notarized drag-to-Applications `.dmg` download or a Homebrew cask. Do not ship it on the
Mac App Store.**

This is not a preference about review overhead. The App Sandbox that the Mac App Store
requires is fundamentally incompatible with what this tool is for.

### What actually breaks under the sandbox

A sandboxed process's restrictions are inherited by every process it spawns. Amp Runner's
entire value is that the `amp` it launches has the same unsandboxed access as the user
session that started the app: the chosen working directory, SSH agent, credentials, MCP
session, and local toolchains. Sandbox that supervisor and you sandbox `amp`, and then
you sandbox `git`, `ssh`, `node`, and every MCP server `amp` starts. Concretely:

- **`~/.ssh` is unreachable.** With `com.apple.security.files.user-selected.read-write`,
  the app can reach the folder the user picked in `NSOpenPanel` and nothing else.
  `git fetch`/`git push` over SSH fails because `ssh` cannot read the private key, the
  `known_hosts` file, or `~/.ssh/config`. The `SSH_AUTH_SOCK` Unix socket handed down from
  the login session is also outside the container.
- **`~/.gitconfig` is unreachable**, so identity, signing config, `insteadOf` rewrites,
  and credential helpers are all silently absent — the runner behaves like a different
  user than the one who launched it.
- **`~/.config/amp/settings.json` is unreachable.** This is Amp's own configuration,
  including the `amp.remoteThreadCreation.enabled` flag this app checks and the MCP server
  definitions. A sandboxed Amp Runner cannot read it to warn the user, cannot offer to
  enable the flag, and the sandboxed `amp` child cannot read it either.
- **Installer and Homebrew paths are unreachable.** The shell installer puts the real
  binary at `${AMP_HOME:-$HOME/.amp}/bin/amp`, while Homebrew links it from
  `/opt/homebrew/bin/amp` or `/usr/local/bin/amp`. A sandboxed app cannot execute a
  binary in an arbitrary location outside its container, so the app cannot even start
  the process it exists to supervise — and if it could, `amp`'s own dependencies (`node`,
  `git`, language toolchains) live in similarly unreachable locations.
- **Existing OAuth/MCP sessions are unreachable.** Whatever Jira/Atlassian or other MCP
  integration the user has already authenticated in their normal environment lives in
  files or keychain items outside the container, so remote threads that depend on those
  integrations fail in ways that look like Amp bugs rather than sandbox denials.

The net effect is that a sandboxed build can supervise `amp` only inside one
self-contained directory with no external tooling and no credentials — which is not the
job.

### Why the one workaround is not viable

The only mechanism Apple provides for reaching arbitrary fixed paths from a sandboxed app
is the `com.apple.security.temporary-exception.*` family (for example
`temporary-exception.files.home-relative-path.read-write` for `~/.ssh`). These are
explicitly documented as temporary measures for pre-release and in-house software while an
app is migrated to the sandbox. App Review treats them as an escape hatch requiring
per-entitlement justification and routinely rejects them for shipping consumer apps, and
even when granted they are not a stable foundation — an app whose core function depends on
a temporary exception is one review cycle away from being unshippable. Enumerating every
path `amp`'s children might need (`~/.ssh`, `~/.gitconfig`, `~/.config`, `/opt/homebrew`,
`/usr/local`, plus whatever a given repo's toolchain requires) is also not possible in
advance, so the exception list could never be complete.

Developer ID with Hardened Runtime and notarization gives users the same Gatekeeper
guarantees — the app is signed by an identified developer and has been scanned by Apple —
without the sandbox. Notably, no Hardened Runtime *exceptions* are needed either: Amp
Runner does not JIT, does not load unsigned plug-ins, and does not disable library
validation. It only spawns a separate, independently signed process, which Hardened
Runtime permits.

### The App Store target is still here

`AmpRunner-AppStore` builds the same sources against
`App/Resources/AmpRunner-AppStore.entitlements` (app-sandbox, network client,
user-selected read-write, app-scope bookmarks). It exists so the option is one build away
if Apple's stance changes, if the user's needs change, or for the genuinely narrow case
where a single self-contained working directory with no external credentials is all that
is needed — in that case the sandbox is not merely tolerable but preferable.
`SecurityScopedBookmarkStore` is written unconditionally for this reason: security-scoped
bookmarks are required inside the sandbox and harmless outside it, so both targets share
one code path.

## 4. Status detection caveat

Runner status comes from two sources with very different reliability, and they are
versioned separately on purpose.

**Authoritative — monitored process liveness and exit code.** `ProcessSupervisor`
observes `Process.terminationHandler` for the native helper that starts Amp. The helper
mirrors Amp's normal exit status, exits cleanly when the app explicitly stops it, and
forwards a graceful shutdown if the app PID disappears because Xcode stopped it or the app
crashed. A clean exit becomes `.stopped`; a non-zero exit becomes `.error("exit code N")`;
termination by signal becomes `.stopped`. This is always more reliable than what Amp
printed. A parsed log line is never allowed to override it: `ProcessSupervisor` only
applies a log-implied status while the process is still running, so a stale "connected"
line cannot resurrect a dead runner.

**Best-effort — log-line matching.** The distinction between `.online` (connected, waiting
for work) and `.working` (executing a remote thread) can only come from Amp's console
output, which is not a documented or stable interface. The phrases in
`RunnerLogParser.defaultMatchers` — notably `"remote controlling the app runner"` — were
observed in a Sourcegraph demo and may change with any Amp release. The matcher table is
therefore isolated as plain data: each rule is a list of required phrases, a list of
disqualifying phrases, and a closure producing an event. Correcting or adding a phrase is a
one-line change in one file, needs no change to the supervisor, and is directly unit
testable. Any line that matches nothing becomes `.unrecognizedLine`, which implies no
status change at all — an unknown line must never move the state machine.

If the Online/Working distinction ever looks wrong, that is a matcher-table bug. If
Stopped/Error looks wrong, that is a real bug.

## 5. Security model

These properties are non-negotiable and are implemented literally.

1. **Explicit folder choice.** A profile's working directory can only be set through
   `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`,
   `allowsMultipleSelection = false`). The app never defaults to an arbitrary directory —
   a new profile's working directory starts empty and fails validation until the user
   picks one.
2. **Confirm before start.** `RunnerProfile.confirmBeforeStart` defaults to `true`.
   Starting a runner presents a sheet showing the resolved executable path, the full
   argument list, and the resolved working directory. The native monitor helper receives
   the same `ResolvedRunnerCommand` and launches Amp directly with that working directory
   and argument list. "Don't ask again" is a deliberate per-profile opt-out, not the
   default.
3. **No credential storage, ever.** The app persists only its own non-secret
   configuration: profiles as JSON at
   `~/Library/Application Support/AmpRunner/profiles.json`, and global user-added `PATH`
   directories in macOS preferences. There is no Keychain usage for secrets anywhere in
   the codebase. Atlassian refresh tokens, Git/SSH credentials, and OAuth tokens are never
   read, stored, exported, or logged. Amp Runner does not provide secrets support.
4. **Never root, never a daemon.** Everything runs in the logged-in user's GUI session.
   There is no privileged helper, no `launchd` daemon, and no `setuid` anything. The
   login-at-start toggle registers exactly one app-level LaunchAgent, via
   `SMAppService.agent(plistName:)`, instead of a `LaunchAgent` per profile: per-profile
   agents would duplicate runner ownership outside the app's supervision model. The
   app-level LaunchAgent lets `launchd` restart Amp Runner after an unsuccessful exit,
   while the app still starts `autoStart` profiles itself after launching.
5. **One profile, one isolated directory.** `RunnerProfileStore.validate` rejects any save
   where two profiles resolve to the same working directory (compared on standardised
   paths, so `/a/b`, `/a/b/`, and `/a/./b` collide) or share a runner ID. This matches
   Amp's own identity model, where a runner is host plus working directory. Duplicating a
   profile deliberately clears the copy's directory so the user must choose a new one.

One more property worth stating: the app refuses to rewrite
`~/.config/amp/settings.json` if it cannot parse it. The "Enable Remote Thread Creation"
action merges a single key into the existing JSON, preserving every other key, and a
malformed file produces a warning telling the user to fix it by hand rather than a silent
clobber.

## 6. Milestones

- **M1 — Core package + tests.** `AmpRunnerCore` with profile model, command builder, log
  parser, profile store, and settings checker, all green under `swift test`. *(Complete.)*
- **M2 — Menu bar shell + profile CRUD.** `MenuBarExtra` with per-profile submenus, the
  `Settings` scene hosting the profile list and editor, `NSOpenPanel` folder selection, and
  JSON persistence.
- **M3 — Process supervision + log viewer + confirmation sheet.** `ProcessSupervisor` with
  the bundled native parent-death monitor, 500-line ring buffer, SIGINT-then-SIGTERM shutdown,
  log mirroring to `~/Library/Logs/AmpRunner/`, and the start-confirmation sheet.
- **M4 — Notifications + login item.** `UNUserNotificationCenter` events for thread
  start/finish/failure and the `SMAppService` login-item toggle.
- **M5 — Signing, notarization, distribution.** Developer ID signing with Hardened
  Runtime, `notarytool` submission and stapling, and a notarized drag-to-Applications
  `.dmg` release with checksum and provenance manifest.
