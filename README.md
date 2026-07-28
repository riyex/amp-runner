# Amp Runner

Amp Runner is a native macOS menu-bar app that supervises local
[Amp](https://ampcode.com) runner processes. Amp's headless runner mode
(`amp --no-tui`) connects back to ampcode.com and waits to accept threads you create
from the web or your phone, executing them in a local working directory — but it gives
you no way to see whether your runners are up, and no way to run several of them (one
per repository) without keeping terminal windows open. Amp Runner is that front end and
nothing more: it spawns your own `amp` binary as a child process, shows its status in the
menu bar, and lets you start, stop, and inspect each runner. It does not reimplement,
wrap, proxy, or modify Amp's protocol, and every command it runs is shown to you before
it runs so you can reproduce it in a terminal.

## Prerequisites

- **macOS 14 (Ventura) or later.**
- **Xcode 15 or later**, for building the app.
- **XcodeGen**, which generates the Xcode project from `project.yml`:
  ```sh
  brew install xcodegen
  ```
- **The Amp CLI**, installed and logged in:
  ```sh
  curl -fsSL https://ampcode.com/install.sh | bash
  amp login
  ```
  Amp Runner auto-detects the binary via `which amp`, falling back to
  `/opt/homebrew/bin/amp` and `/usr/local/bin/amp`. You can also point a profile at any
  path yourself.
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

Or build the Developer ID target from the command line:

```sh
./Scripts/build_developer_id.sh
```

Two targets are generated from the same sources:

| Target | Entitlements | Use |
| --- | --- | --- |
| `AmpRunner` | `App/Resources/AmpRunner.entitlements` (no sandbox) | Direct distribution — **recommended** |
| `AmpRunner-AppStore` | `App/Resources/AmpRunner-AppStore.entitlements` (sandboxed) | Kept for the narrow case where it works |

`AmpRunner.xcodeproj` is generated and git-ignored; edit `project.yml`, not the project
file.

## Tests

The portable core has no UI dependencies, so its tests run anywhere Swift does:

```sh
swift test
```

This covers the profile model and its validation rules, the command builder, the log-line
parser, the JSON profile store, and the Amp settings checker — including that a saved
profile's JSON contains no secrets and that two profiles can never claim the same working
directory.

## Using it

1. Open the menu-bar icon and choose **New Profile…** (or the one-click **SampleProject** quick
   start on first launch).
2. Give the profile a name and runner ID, then pick its working directory. The folder
   picker is the only way to set it — Amp Runner never defaults to a directory you did
   not choose.
3. Start the runner. A confirmation sheet shows the exact executable path, the full
   argument list, and the resolved working directory before anything is spawned. This is
   on by default; "don't ask again" is a per-profile opt-out.
4. The menu bar shows each runner's state: Stopped, Starting, Online (connected, waiting
   for work), Working (executing a thread), or Error. Per-profile submenus give you logs,
   Finder/Terminal access, and a copyable version of the exact command.

Notifications for thread start / finish / failure and a **Start Amp Runner at Login**
toggle are both in the menu.

## Credentials

**Amp Runner never reads, stores, exports, or logs your credentials.** There is no
Keychain usage for secrets anywhere in the codebase. Atlassian refresh tokens, OAuth
tokens, and Git/SSH credentials are never touched. The only thing persisted is Amp
Runner's own non-secret configuration — profile names, runner IDs, paths, arguments, and
flags — as JSON at `~/Library/Application Support/AmpRunner/profiles.json`.

The `amp` process Amp Runner spawns reaches its own credentials through your normal
environment, exactly as it would if you ran it in a terminal. Amp Runner also never runs
as root and installs no daemon or privileged helper; everything runs in your logged-in
user session.

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
