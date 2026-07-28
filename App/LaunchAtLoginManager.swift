import Foundation
import ServiceManagement

/// Single app-level "Start Amp Runner at login" toggle, backed by `SMAppService.mainApp`
/// (macOS 13+).
///
/// Design choice: there is deliberately **one** login item — the app itself. We do not
/// register a LaunchAgent per profile. Per-profile agents would run `amp` outside the
/// user's GUI session with a stripped environment (no SSH agent, different PATH), which
/// is exactly what this app exists to avoid, and they would also duplicate supervision
/// state across two owners. Instead the app launches at login and then starts whichever
/// profiles have `autoStart` enabled, from inside the user's normal session.
@MainActor
final class LaunchAtLoginManager: ObservableObject {

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Returns `true` when the requested state was reached.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                // Re-registering an already-registered service throws; treat the
                // already-enabled case as success.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
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
        SMAppService.mainApp.status == .requiresApproval
    }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not enabled"
        case .requiresApproval: return "Awaiting approval in System Settings › General › Login Items"
        case .notFound: return "Login item not found"
        @unknown default: return "Unknown"
        }
    }
}
