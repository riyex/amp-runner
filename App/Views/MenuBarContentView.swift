import SwiftUI
import AppKit
import AmpRunnerCore

/// Which pane the Settings window should show when it is next opened from the menu.
enum SettingsPane: Hashable {
    case general
    case runners
    case environment
    case updates
    case logs
}

/// Opens the app's single `Settings` scene from AppKit.
///
/// The window is declared in `AmpRunnerApp` with the same id, and opened from the menu
/// using SwiftUI's `openWindow` environment action.
enum SettingsWindowOpener {
    static let windowID = "profile-manager"

    static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Contents of the menu bar dropdown.
struct MenuBarContentView: View {
    @ObservedObject var coordinator: RunnerCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if coordinator.ampSettingsResult.needsAttention && !coordinator.isAmpSettingsWarningDismissed {
            Text(coordinator.ampSettingsResult.userFacingMessage)
            if canAutoEnableRemoteThreadCreation {
                Button("Enable Remote Thread Creation") {
                    coordinator.enableRemoteThreadCreation()
                }
            }
            Button("Dismiss Warning") {
                coordinator.isAmpSettingsWarningDismissed = true
            }
            Divider()
        }

        if let loadError = coordinator.loadError {
            Text(loadError)
            Divider()
        }

        if coordinator.profiles.isEmpty {
            Text("No runner profiles yet")
            Button("New Runner…") { open(.runners, draft: .new) }
        } else {
            ForEach(coordinator.profiles) { profile in
                profileMenu(for: profile)
            }
            Divider()
            Button("Stop All Runners") { coordinator.stopAll() }
                .disabled(!coordinator.profiles.contains { coordinator.status(for: $0).isRunning })
        }

        Divider()

        Button("Manage Runners…") { open(.runners, draft: .none) }
        Button("Environment…") { open(.environment, draft: .none) }
        Button(updatesMenuTitle) { open(.updates, draft: .none) }
        Button("Check Amp Settings") { checkAmpSettings() }

        Divider()

        Button("About Amp Runner") { showAbout() }
        Button("Quit Amp Runner") {
            coordinator.onTerminate()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Per-profile submenu

    @ViewBuilder
    private func profileMenu(for profile: RunnerProfile) -> some View {
        let status = coordinator.status(for: profile)

        Menu("\(statusGlyph(status))  \(profile.name) — \(status.detailedDescription)") {
            Text(updateDescription(for: profile))
            if case .restartRequired = coordinator.updateState(for: profile), status.isRunning {
                Button("Restart to Update") { coordinator.restartToUpdate(profile) }
            }
            Divider()
            if status.isRunning {
                Button("Stop") { coordinator.stop(profile) }
                Button("Restart") { coordinator.restart(profile) }
            } else {
                Button("Start") { startFromMenu(profile) }
            }

            if let summary = coordinator.threadSummary(for: profile) {
                Divider()
                Text(summary)
            }

            Divider()

            Button("Open Folder in Finder") { coordinator.revealWorkingDirectoryInFinder(profile) }
            Button("Open Folder in Terminal") { coordinator.openWorkingDirectoryInTerminal(profile) }
            if coordinator.threadURLString(for: profile) != nil {
                Button("Open Current Thread on ampcode.com") { coordinator.openOnAmpCode(profile) }
                Button("Open Runner on ampcode.com") { coordinator.openRunnerOnAmpCode(profile) }
            } else {
                Button("Open on ampcode.com") { coordinator.openRunnerOnAmpCode(profile) }
            }

            Divider()

            Button("View Logs…") {
                coordinator.logViewerProfileID = profile.id
                open(.logs, draft: .none)
            }
            Button("Copy Recent Logs") {
                coordinator.copyToPasteboard(coordinator.logLines(for: profile.id).joined(separator: "\n"))
            }
            Button("Copy Command") {
                coordinator.copyToPasteboard(coordinator.commandPreview(for: profile))
            }

            Divider()

            Button("Edit…") { open(.runners, draft: .edit(profile.id)) }
            Button("Duplicate…") { open(.runners, draft: .duplicate(profile.id)) }
        }
    }

    /// Plain-text glyphs rather than SF Symbols: items inside a menu-styled
    /// `MenuBarExtra` are rendered as `NSMenuItem`s and only reliably show their title.
    private func statusGlyph(_ status: RunnerStatus) -> String {
        switch status {
        case .stopped: return "○"
        case .starting: return "◐"
        case .online: return "●"
        case .working: return "◆"
        case .error: return "▲"
        }
    }

    // MARK: - Actions

    /// A menu item cannot host a sheet, so a start that needs confirmation brings the
    /// Settings window forward and presents the confirmation sheet there.
    private func startFromMenu(_ profile: RunnerProfile) {
        coordinator.requestStart(profile)
        if coordinator.pendingConfirmation != nil {
            open(.runners, draft: .none)
        }
    }

    private func open(_ pane: SettingsPane, draft: ProfileDraftRequest) {
        coordinator.settingsPane = pane
        coordinator.draftRequest = draft
        openWindow(id: SettingsWindowOpener.windowID)
        SettingsWindowOpener.activateApp()
    }

    private func checkAmpSettings() {
        let result = coordinator.checkAmpSettings()
        let alert = NSAlert()
        alert.messageText = "Amp Settings"
        alert.informativeText = result.userFacingMessage
        alert.alertStyle = result.needsAttention ? .warning : .informational
        alert.addButton(withTitle: "OK")
        SettingsWindowOpener.activateApp()
        alert.runModal()
    }

    private func showAbout() {
        let credits = NSAttributedString(
            string: AmpRunnerBranding.nonAffiliationNotice,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        SettingsWindowOpener.activateApp()
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }

    private var updatesMenuTitle: String {
        let count = coordinator.restartRequiredRunnerCount
        return count == 0 ? "Updates…" : "Updates… — \(count) runner\(count == 1 ? "" : "s") need restart"
    }

    private func updateDescription(for profile: RunnerProfile) -> String {
        switch coordinator.updateState(for: profile) {
        case .versionUnknown: return "Amp version unknown"
        case .upToDate(let version): return "Amp \(version)"
        case .updateAvailable(_, let latest): return "Update available: \(latest)"
        case .installing(let installed): return installed.map { "Installing update (Amp \($0))" } ?? "Installing update"
        case .restartRequired(_, let installed): return "Restart required for \(installed)"
        case .updateFailed(let installed, _): return installed.map { "Amp \($0) — update failed" } ?? "Amp version unknown — update failed"
        }
    }

    /// Only offer one-click enabling when the file could actually be parsed. A malformed
    /// `settings.json` must be fixed by hand rather than clobbered.
    private var canAutoEnableRemoteThreadCreation: Bool {
        switch coordinator.ampSettingsResult {
        case .disabled, .notConfigured, .missingFile: return true
        case .enabled, .malformed: return false
        }
    }
}
