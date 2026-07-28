import Foundation
import UserNotifications
import AmpRunnerCore

/// Posts local notifications for remote-thread lifecycle events.
///
/// Authorization is requested lazily, the first time a notification would actually be
/// posted, so a user who never turns notifications on is never prompted.
@MainActor
final class RunnerNotifier: ObservableObject {

    /// Global opt-in. Persisted in `UserDefaults` — non-secret UI preference only.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "com.riyex.amprunner.notificationsEnabled"

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    private var authorizationRequested = false
    private var isAuthorized = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        // `current()` traps in unbundled contexts (e.g. previews / command-line runs);
        // guarding keeps the rest of the app usable there.
        self.center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func notify(event: RunnerEvent, profileName: String) {
        guard isEnabled, event.isNotifiable else { return }

        let title: String
        let body: String
        switch event {
        case .threadStarted:
            title = "\(profileName): thread started"
            body = "A remote Amp thread began running."
        case .threadFinished:
            title = "\(profileName): thread finished"
            body = "The remote Amp thread completed."
        case .threadFailed(let detail):
            title = "\(profileName): thread failed"
            body = detail
        case .statusChanged, .unrecognizedLine:
            return
        }

        Task { await post(title: title, body: body) }
    }

    /// Posted when the supervisor itself fails (launch failure, non-zero exit).
    func notifyRunnerError(profileName: String, message: String) {
        guard isEnabled else { return }
        Task { await post(title: "\(profileName): runner stopped", body: message) }
    }

    private func post(title: String, body: String) async {
        guard let center else { return }
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(400))
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            NSLog("AmpRunner: failed to post notification: \(error)")
        }
    }

    private func ensureAuthorized() async -> Bool {
        guard let center else { return false }
        if isAuthorized { return true }

        if !authorizationRequested {
            authorizationRequested = true
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .badge])
            } catch {
                isAuthorized = false
            }
            return isAuthorized
        }

        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        return isAuthorized
    }
}
