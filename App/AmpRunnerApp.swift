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
                .background(SettingsWindowNotificationBridge())
        }
        .menuBarExtraStyle(.menu)

        // The profile list, editor, and log viewer live in an explicitly addressable
        // window so menu-bar actions can open it directly with SwiftUI's openWindow
        // action. LSUIElement keeps the app out of the Dock.
        Window("Amp Runner", id: SettingsWindowOpener.windowID) {
            SettingsRootView(coordinator: appDelegate.coordinator)
        }
        .windowResizability(.contentSize)
    }
}

struct SettingsWindowNotificationBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .ampRunnerOpenSettingsWindow)) { _ in
                openWindow(id: SettingsWindowOpener.windowID)
                SettingsWindowOpener.activateApp()
            }
    }
}

/// Status item contents. Kept as its own observing view so the icon tracks runner state.
struct MenuBarLabelView: View {
    @ObservedObject var coordinator: RunnerCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 15.0,
                paused: aggregateStatus != .working || reduceMotion
            )
        ) { context in
            Image(nsImage: renderedIcon(at: context.date))
                .accessibilityLabel("Amp Runner: \(aggregateStatus.accessibilityDescription)")
        }
    }

    private var aggregateStatus: RunnerAggregateStatus {
        RunnerStatus.menuBarAggregateStatus(
            for: coordinator.profiles.map { coordinator.status(for: $0) }
        )
    }

    private func renderedIcon(at date: Date) -> NSImage {
        let renderer = ImageRenderer(
            content: MenuBarStatusArtwork(
                status: aggregateStatus,
                colorScheme: colorScheme,
                workingPulseOpacity: workingPulseOpacity(at: date)
            )
        )
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 17, height: 18))
    }

    private func workingPulseOpacity(at date: Date) -> Double {
        guard aggregateStatus == .working, !reduceMotion else { return 0.1 }
        let halfCycle = 1.4
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: halfCycle * 2)
        let progress = elapsed <= halfCycle
            ? elapsed / halfCycle
            : 2 - elapsed / halfCycle
        return 0.1 + (0.18 * progress)
    }
}

private struct MenuBarStatusArtwork: View {
    let status: RunnerAggregateStatus
    let colorScheme: ColorScheme
    let workingPulseOpacity: Double

    var body: some View {
        HStack(spacing: 3) {
            Image("MenubarTemplate")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(menuBarForegroundColor)
                .frame(width: 17, height: 17)
                .opacity(status == .stopped ? 0.45 : 1)

            ZStack {
                statusDot
            }
            .frame(width: 12, height: 12)
        }
        .frame(height: 18)
        .fixedSize()
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .stopped:
            EmptyView()
        case .starting:
            Circle()
                .stroke(mintColor, lineWidth: 1.2)
                .frame(width: 5, height: 5)
        case .online:
            Circle()
                .fill(mintColor)
                .frame(width: 5, height: 5)
        case .working:
            ZStack {
                Circle()
                    .fill(mintColor.opacity(workingPulseOpacity))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(mintColor)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 12, height: 12)
        case .error:
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 5, height: 5)
        }
    }

    private var menuBarForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var mintColor: Color {
        colorScheme == .dark
            ? Color(red: 0.353, green: 0.820, blue: 0.659)
            : Color(red: 0.184, green: 0.561, blue: 0.427)
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
    @State private var selectedPane: SettingsPane

    init(coordinator: RunnerCoordinator) {
        self.coordinator = coordinator
        _selectedPane = State(initialValue: coordinator.settingsPane)
    }

    var body: some View {
        TabView(selection: $selectedPane) {
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
        .task(id: coordinator.settingsPane) {
            selectedPane = coordinator.settingsPane
        }
        .onAppear { coordinator.launchAtLogin.refresh() }
    }
}
