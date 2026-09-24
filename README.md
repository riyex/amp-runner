# Amp Runner

[![CI](https://github.com/riyex/amp-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/riyex/amp-runner/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

<img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="96" alt="Amp Runner icon">

Amp Runner is a native macOS menu-bar app that supervises local
[Amp](https://ampcode.com) runner processes. Amp's headless runner mode
(`amp --no-tui`) connects back to ampcode.com and waits to accept threads you create
from the web or your phone, executing them across the directories each runner serves.
Amp Runner lets you supervise one or several runners without keeping terminal windows
open. It is that front end and
nothing more: it runs your own `amp` binary as a supervised child process, shows its status in the
menu bar, and lets you start, stop, and inspect each runner. It does not reimplement,
wrap, proxy, or modify Amp's protocol, and it can show an equivalent terminal command so
you can reproduce a runner outside the app.

The icon uses the Threads mark: three lanes bundling through one waist, then running on.

Amp Runner is an independent project and is not affiliated with, endorsed by, sponsored
by, or connected to Sourcegraph, Amp, or AmpCode.

## Installation status

Amp Runner does not yet have a supported binary release. Build it from source using the
steps below. Future binaries will be signed with a Developer ID certificate and notarized
before publication.

## Prerequisites

- **macOS 14 (Sonoma) or later.**
- **Xcode 15 or later**, for building the app.
- **XcodeGen**, which generates the Xcode project from `project.yml`:
  ```sh
  brew install xcodegen
  ```
- **The Amp CLI, version `0.0.1790103932-g7c3282` or later**, installed and logged in:
  ```sh
  curl -fsSL https://ampcode.com/install.sh | bash
  amp login
  ```
  Amp Runner auto-detects the installer-owned binary at `$AMP_HOME/bin/amp` or
  `~/.amp/bin/amp`, then checks the app's inherited `PATH`, Homebrew prefixes
  (`/opt/homebrew/bin/amp`, `/usr/local/bin/amp`), and legacy wrapper locations
  (`~/.local/bin/amp`, `~/bin/amp`, `~/.bin/amp`). You can also point a profile at any
  path yourself.
  At startup, the app checks each configured executable with `--version` (or the
  detected executable when no profiles exist). Older or unverifiable installations
  trigger an upgrade warning and cannot start runners. Each start rechecks, so after
  upgrading in Terminal you can retry without relaunching the app. The minimum is a
  conservative known-good September 22, 2026 build, not necessarily the first release
  containing the features. This is a local compatibility check, not release polling.
- **Remote thread creation enabled** in `~/.config/amp/settings.json`:
  ```json
  { "amp.remoteThreadCreation.enabled": true }
  ```
  Amp Runner checks this at launch and offers to set it for you, merging the single key
  and preserving everything else in the file. If the file cannot be parsed, it refuses to
  touch it and asks you to fix it by hand.

## Build

Generate the Xcode project and open it:

```sh
./Scripts/generate_project.sh
open AmpRunner.xcodeproj
```

Maintainers can prepare a signed and notarized DMG from an annotated release tag:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID ./Scripts/prepare_release.sh vX.Y.Z
```

See the [release runbook](docs/RELEASING.md) for versioning, tagging, smoke testing, and
draft GitHub Release publication.

Two app targets are generated from the same sources:

| Target | Entitlements | Use |
| --- | --- | --- |
| `AmpRunner` | `App/Resources/AmpRunner.entitlements` (no sandbox) | Direct distribution — **recommended** |
| `AmpRunner-AppStore` | `App/Resources/AmpRunner-AppStore.entitlements` (sandboxed) | Kept for the narrow case where it works |

A small `AmpRunnerMonitor` command-line helper is also built and copied into
`AmpRunner.app/Contents/Helpers/` so runners are shut down if the app is stopped by Xcode
or crashes.

`AmpRunner.xcodeproj` is generated and git-ignored; edit `project.yml`, not the project
file.

## Tests

The core and monitor support have no UI dependencies, so their tests run from SwiftPM
without opening Xcode:

```sh
swift test
```

This covers the profile model and its validation rules, the command builder, the native
monitor helper, the log-line parser, the JSON profile store, and the Amp settings checker
— including that a saved profile's JSON contains no secrets and that two profiles can
never claim the same working directory.

macOS is the only supported and tested platform. The core and monitor retain conditional
Linux plumbing, but the project does not currently claim Linux compatibility.

## Using it

1. Open the menu-bar icon and choose **New Profile…**.
2. Give the profile a name and runner ID, then pick its launch directory. The folder
   picker is the only way to set it — Amp Runner never defaults to a directory you did
   not choose. New runners discover Git checkouts beneath that folder by default
   (`--discover-dirs`). Add more discovery folders or explicit directories (`--dir`),
   or turn off discovery entirely. Turn off **Serve the launch directory itself** to
   advertise only your selected directories. Amp still permits requests to its launch
   directory; this setting is not an access-control boundary.
3. Start the runner. A confirmation sheet shows the Amp executable path, the full
   argument list, and the resolved working directory before anything is launched. This is
   on by default; "don't ask again" is a per-profile opt-out.
4. The menu bar shows each runner's state: Stopped, Starting, Online (connected, waiting
   for work), Working (executing a thread), or Error. Per-profile submenus give you logs,
   Finder/Terminal access, and a copyable equivalent terminal command.

Choose **Directories…** from a runner's menu-bar submenu or Manage Runners to list,
add, or remove live directories without restarting. Amp persists live additions against
the launch directory. **Remove Added Directory** only undoes a live addition; it never
deletes files. Launch-configured directories and discovery roots are edited in the
profile and apply after restart. To exclude a discovered repository, use
`--discover-exclude` and its pattern in **Advanced Arguments**. A directory may still be
served by another source. Directory commands always target the running instance's ID,
executable, launch directory, settings file, and environment, even if its profile has
been edited since launch.

**Use Amp Secrets & Env Vars** defaults to on for new runners and adds `--amp-env`.
Amp fetches the personal, project, and workspace variables; this app does not store
their values. Turning it off omits the flag, but Amp's own settings can still enable
the feature. Existing saved profiles keep their previous arguments, without silently
enabling discovery or cloud variables.

**Share this runner with my workspace** adds `--share`, making the runner and its served
directories available to workspace members on ampcode.com. Their threads run as your
macOS user and can access your files, credentials, and logins, so enable sharing only for
people you trust. Sharing remains off by default. The profile editor and start
confirmation both display this warning when sharing is enabled.

Settings has four panes, in order: **General**, **Runners**, **Environment**, and **Logs**.
General contains **Start Amp Runner at Login** and the thread lifecycle notification
choices. Amp runners update themselves; Amp Runner does not check for Amp releases,
install updates, notify about newer releases, or restart runners because an update occurred.
It only prompts when an installation does not meet the minimum-version requirement or
cannot be verified.
Amp's own settings control automatic updates. Homebrew installations still need to be
updated through Homebrew. See the [runner documentation](https://ampcode.com/docs/cli/runners).

The Settings window has one global **Environment** tab for every profile. Its ordered user
directories are prepended to the runner `PATH`, followed by the app-inherited `PATH` entries
and existing conventional developer and system directories. Amp Runner normalizes and
deduplicates those entries. It preserves a missing absolute user directory and warns about
it, but does not save empty, relative, or colon-containing entries. A changed `PATH` applies
when a profile starts or restarts; a running process keeps the environment it received when
it launched.

## Credentials

**Amp Runner never reads, stores, exports, or logs your credentials.** There is no
Keychain usage for secrets anywhere in the codebase. Atlassian refresh tokens, OAuth
tokens, and Git/SSH credentials are never touched. Amp Runner persists only its own
non-secret settings. Profiles are stored as JSON at
`~/Library/Application Support/AmpRunner/profiles.json`, plus global user-added `PATH`
directories and notification preferences in macOS preferences.

Amp Runner does not execute a login shell or source shell startup files, so it does not
promise complete Terminal-environment parity. Cloud variables are managed by Amp via
`--amp-env`, not stored in this app. Amp Runner also never runs as root and installs no daemon or privileged
helper; everything runs in your logged-in user session.

## Distribution

Amp Runner is intended to ship **outside the Mac App Store**, signed with a Developer ID
certificate, built with the Hardened Runtime, and notarized. This is not about review
overhead — the App Sandbox is inherited by every process the app spawns, which would cut
`amp` (and the `git`, `ssh`, and MCP servers it starts) off from `~/.ssh`, `~/.gitconfig`,
`~/.config/amp/settings.json`, and Homebrew prefixes. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the full reasoning, including why the
`com.apple.security.temporary-exception.*` entitlements are not a viable workaround and
why the App Store target still exists.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the core/UI split, the status-detection
caveats (exit codes are authoritative; the Online/Working distinction is heuristic
log matching), the security model, and the milestone plan.

## Project information

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Maintainer release process](docs/RELEASING.md)
- [Apache License 2.0](LICENSE)
