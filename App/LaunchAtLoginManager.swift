import Foundation
import ServiceManagement

/// Single app-level "Start Amp Runner at login" toggle, backed by a bundled
/// `SMAppService` LaunchAgent (macOS 13+).
///
/// Design choice: there is deliberately **one** LaunchAgent — the app-level relaunch
/// entry. We do not register a LaunchAgent per profile. Per-profile agents would run
/// `amp` outside the app's supervision model and duplicate ownership state across two
/// places. Instead the app launches at login and starts whichever profiles have
/// `autoStart` enabled, from inside the user's normal GUI session.
@MainActor
final class LaunchAtLoginManager: ObservableObject {

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    private static let agentPlistName = "com.riyex.amprunner.agent.plist"

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = launchAgentService.status == .enabled
    }

    /// Returns `true` when the requested state was reached.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                // Re-registering an already-registered service throws; treat the
                // already-enabled case as success.
                try unregisterLegacyMainAppIfNeeded()
                if launchAgentService.status != .enabled {
                    try launchAgentService.register()
                }
            } else {
                if Self.canUnregister(status: launchAgentService.status) {
                    try launchAgentService.unregister()
                }
                try unregisterLegacyMainAppIfNeeded()
            }
        } catch {
            lastError = error.localizedDescription
            refresh()
            return false
        }
        refresh()
        return isEnabled == enabled
    }

    /// macOS may put the login item in a "requires user approval" state after the user
    /// denies it in System Settings; surface that so the UI can explain it.
    var requiresApproval: Bool {
        launchAgentService.status == .requiresApproval
            || SMAppService.mainApp.status == .requiresApproval
    }

    var statusDescription: String {
        switch launchAgentService.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not enabled"
        case .requiresApproval: return "Awaiting approval in System Settings › General › Login Items"
        case .notFound: return "LaunchAgent not found in app bundle"
        @unknown default: return "Unknown"
        }
    }

    private var launchAgentService: SMAppService {
        SMAppService.agent(plistName: Self.agentPlistName)
    }

    private static func canUnregister(status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private func unregisterLegacyMainAppIfNeeded() throws {
        guard SMAppService.mainApp.status == .enabled else { return }
        try SMAppService.mainApp.unregister()
    }
}
