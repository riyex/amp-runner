import SwiftUI
import AppKit
import AmpRunnerCore

@main
struct AmpRunnerApp: App {
    /// The delegate owns the coordinator so that launch-time work (restoring folder
    /// bookmarks, checking Amp settings, auto-starting profiles) happens even when the
    /// user never opens a window — which, for a menu-bar-only app, is the normal case.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                coordinator: appDelegate.coordinator,
                launchAtLogin: appDelegate.coordinator.launchAtLogin,
                notifier: appDelegate.coordinator.notifier
            )
        } label: {
            MenuBarLabelView(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        // The profile list, editor, and log viewer live in a `Settings` scene rather
        // than a `WindowGroup`: for an LSUIElement app this is the scene type that can
        // be brought forward on demand without ever adding a Dock icon.
        Settings {
            SettingsRootView(coordinator: appDelegate.coordinator)
        }
    }
}

/// Status item contents. Kept as its own observing view so the icon tracks runner state.
struct MenuBarLabelView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    var body: some View {
        Image(systemName: symbolName)
    }

    private var symbolName: String {
        let statuses = coordinator.profiles.map { coordinator.status(for: $0) }
        if statuses.contains(where: { if case .error = $0 { return true } else { return false } }) {
            return "exclamationmark.triangle"
        }
        if statuses.contains(.working) { return "bolt.horizontal.circle.fill" }
        if statuses.contains(.online) { return "bolt.horizontal.circle" }
        return "bolt.horizontal"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = RunnerCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: Info.plist sets LSUIElement, but setting the policy here too
        // means a build launched directly from Xcode still behaves as an accessory app.
        NSApp.setActivationPolicy(.accessory)
        coordinator.onLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.onTerminate()
    }

    /// Menu-bar-only app: closing the Settings window must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Root of the `Settings` scene: profile management, logs, and the start-confirmation
/// sheet.
struct SettingsRootView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    private var paneBinding: Binding<SettingsPane> {
        Binding(
            get: { coordinator.settingsPane },
            set: { coordinator.settingsPane = $0 }
        )
    }

    var body: some View {
        TabView(selection: paneBinding) {
            ProfileListView(coordinator: coordinator)
                .tabItem { Label("Profiles", systemImage: "list.bullet") }
                .tag(SettingsPane.profiles)

            LogViewerView(coordinator: coordinator)
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(SettingsPane.logs)
        }
        .frame(minWidth: 660, minHeight: 460)
        .sheet(item: $coordinator.pendingConfirmation) { pending in
            StartConfirmationView(
                profile: pending.profile,
                command: pending.command,
                onStart: { remember in coordinator.confirmPendingStart(rememberChoice: remember) },
                onCancel: { coordinator.cancelPendingStart() }
            )
        }
        .onAppear { coordinator.launchAtLogin.refresh() }
    }
}
