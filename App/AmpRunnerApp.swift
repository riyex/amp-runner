import SwiftUI
import AppKit
import AmpRunnerCore
import Darwin

@main
struct AmpRunnerApp: App {
    /// The delegate owns the coordinator so that launch-time work (restoring folder
    /// bookmarks, checking Amp settings, auto-starting profiles) happens even when the
    /// user never opens a window — which, for a menu-bar-only app, is the normal case.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                coordinator: appDelegate.coordinator
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

    var body: some View {
        MenuBarStatusImage(status: aggregateStatus, colorScheme: colorScheme)
            .equatable()
    }

    private var aggregateStatus: RunnerAggregateStatus {
        RunnerStatus.menuBarAggregateStatus(
            for: coordinator.profiles.map { coordinator.status(for: $0) }
        )
    }
}

private struct MenuBarStatusImage: View, Equatable {
    let status: RunnerAggregateStatus
    let colorScheme: ColorScheme

    var body: some View {
        Image(nsImage: renderedIcon())
            .accessibilityLabel("Amp Runner: \(status.accessibilityDescription)")
    }

    private func renderedIcon() -> NSImage {
        let renderer = ImageRenderer(
            content: MenuBarStatusArtwork(
                status: status,
                colorScheme: colorScheme
            )
        )
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 17, height: 18))
    }
}

private struct MenuBarStatusArtwork: View {
    let status: RunnerAggregateStatus
    let colorScheme: ColorScheme

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
                    .fill(mintColor.opacity(0.2))
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
        // The XCTest host launches the app executable but must not load the user's
        // profiles or start real runners as a side effect of unit tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !Self.terminateIfDuplicateInstance() else { return }
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

    private static func terminateIfDuplicateInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let current = InstanceIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            launchDate: NSRunningApplication.current.launchDate,
            processID: currentProcessID,
            processStartTime: Self.processStartTime(for: currentProcessID)
        )
        let olderMatchingInstanceExists = NSWorkspace.shared.runningApplications.contains { application in
            let candidate = InstanceIdentity(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                launchDate: application.launchDate,
                processID: application.processIdentifier,
                processStartTime: Self.processStartTime(for: application.processIdentifier)
            )
            return Self.isOlderMatchingInstance(candidate, than: current)
        }

        if olderMatchingInstanceExists {
            NSApp.terminate(nil)
        }
        return olderMatchingInstanceExists
    }

    struct InstanceIdentity {
        let bundleIdentifier: String?
        let bundleURL: URL?
        let launchDate: Date?
        let processID: pid_t
        let processStartTime: ProcessStartTime?
    }

    static func isOlderMatchingInstance(
        _ candidate: InstanceIdentity,
        than current: InstanceIdentity
    ) -> Bool {
        guard candidate.bundleIdentifier == current.bundleIdentifier else { return false }
        return wasLaunchedBeforeCurrentProcess(
            candidateLaunchDate: candidate.launchDate,
            candidateProcessID: candidate.processID,
            candidateProcessStartTime: candidate.processStartTime,
            currentLaunchDate: current.launchDate,
            currentProcessID: current.processID,
            currentProcessStartTime: current.processStartTime
        )
    }

    static func wasLaunchedBeforeCurrentProcess(
        candidateLaunchDate: Date?,
        candidateProcessID: pid_t,
        candidateProcessStartTime: ProcessStartTime?,
        currentLaunchDate: Date?,
        currentProcessID: pid_t,
        currentProcessStartTime: ProcessStartTime?
    ) -> Bool {
        guard candidateProcessID > 0, candidateProcessID != currentProcessID else { return false }

        if let candidateLaunchDate, let currentLaunchDate, candidateLaunchDate != currentLaunchDate {
            return candidateLaunchDate < currentLaunchDate
        }

        if let candidateProcessStartTime,
           let currentProcessStartTime,
           candidateProcessStartTime != currentProcessStartTime {
            return candidateProcessStartTime < currentProcessStartTime
        }

        // Exact or unavailable chronology needs a stable winner so simultaneous launches
        // cannot both terminate. PID is only a tie-breaker after chronology is exhausted.
        return candidateProcessID < currentProcessID
    }

    struct ProcessStartTime: Equatable, Comparable {
        let seconds: UInt64
        let microseconds: UInt64

        static func < (lhs: ProcessStartTime, rhs: ProcessStartTime) -> Bool {
            (lhs.seconds, lhs.microseconds) < (rhs.seconds, rhs.microseconds)
        }
    }

    private static func processStartTime(for processID: pid_t) -> ProcessStartTime? {
        guard processID > 0 else { return nil }

        var processInfo = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &processInfo, expectedSize) == expectedSize else {
            return nil
        }
        return ProcessStartTime(
            seconds: processInfo.pbi_start_tvsec,
            microseconds: processInfo.pbi_start_tvusec
        )
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
            GeneralSettingsView(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)

            ProfileListView(coordinator: coordinator)
                .tabItem { Label("Runners", systemImage: "list.bullet") }
                .tag(SettingsPane.runners)

            EnvironmentSettingsView(coordinator: coordinator)
                .tabItem { Label("Environment", systemImage: "terminal") }
                .tag(SettingsPane.environment)

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
        .onAppear {
            if selectedPane != coordinator.settingsPane {
                selectedPane = coordinator.settingsPane
            }
            coordinator.launchAtLogin.refresh()
        }
        .onChange(of: coordinator.settingsPane) { _, pane in
            if selectedPane != pane {
                selectedPane = pane
            }
        }
        .onChange(of: selectedPane) { _, pane in
            if coordinator.settingsPane != pane {
                coordinator.settingsPane = pane
            }
        }
    }
}
