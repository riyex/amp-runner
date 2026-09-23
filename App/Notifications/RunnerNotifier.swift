import Foundation
import UserNotifications
import AmpRunnerCore

enum RunnerNotificationAction: Equatable {
    case openThread(profileID: UUID?, urlString: String?)
    case viewLogs(profileID: UUID)
}

/// Posts local notifications for remote-thread lifecycle events.
///
/// Authorization is requested lazily, the first time a notification would actually be
/// posted, so a user who never turns notifications on is never prompted.
@MainActor
final class RunnerNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    /// Global opt-in. Persisted in `UserDefaults` — non-secret UI preference only.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    var actionHandler: ((RunnerNotificationAction) -> Void)?

    private static let enabledKey = "com.riyex.amprunner.notificationsEnabled"
    private static let threadCategoryID = "com.riyex.amprunner.notification.thread"
    private static let runnerCategoryID = "com.riyex.amprunner.notification.runner"
    private static let openThreadActionID = "com.riyex.amprunner.notification.action.openThread"
    private static let viewLogsActionID = "com.riyex.amprunner.notification.action.viewLogs"
    private static let profileIDUserInfoKey = "profileID"
    private static let threadURLUserInfoKey = "threadURL"

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    private var authorizationRequested = false
    private var isAuthorized = false

    init(
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        // `current()` traps in unbundled contexts (e.g. previews / command-line runs);
        // guarding keeps the rest of the app usable there.
        self.center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
        configureCategories()
    }

    func notify(event: RunnerEvent, profileID: UUID, profileName: String) {
        guard isEnabled, event.isNotifiable else { return }

        let title: String
        let body: String
        let thread: RunnerThreadDetails?
        switch event {
        case .threadStarted(let details):
            thread = details
            title = "\(profileName): \(details.displayName) started"
            body = metadataBody(for: details, duration: nil, fallback: "A remote Amp thread began running.")
        case .threadFinished(let details, let duration):
            thread = details
            title = "\(profileName): \(details?.displayName ?? "thread") finished"
            body = metadataBody(for: details, duration: duration, fallback: "The remote Amp thread completed.")
        case .threadFailed(let detail, let details, let duration):
            thread = details
            title = "\(profileName): \(details?.displayName ?? "thread") failed"
            let metadata = metadataBody(for: details, duration: duration, fallback: "")
            body = metadata.isEmpty ? detail : "\(metadata)\n\(detail)"
        case .threadIdle, .statusChanged, .unrecognizedLine:
            return
        }

        Task {
            await post(
                title: title,
                body: body,
                profileID: profileID,
                thread: thread,
                categoryIdentifier: Self.threadCategoryID
            )
        }
    }

    /// Posted when the supervisor itself fails (launch failure, non-zero exit).
    func notifyRunnerError(profileID: UUID, profileName: String, message: String) {
        guard isEnabled else { return }
        Task {
            await post(
                title: "\(profileName): runner stopped",
                body: message,
                profileID: profileID,
                thread: nil,
                categoryIdentifier: Self.runnerCategoryID
            )
        }
    }

    private func post(
        title: String,
        body: String,
        profileID: UUID,
        thread: RunnerThreadDetails?,
        categoryIdentifier: String
    ) async {
        guard let center else { return }
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(400))
        content.sound = nil
        content.categoryIdentifier = categoryIdentifier
        var userInfo: [String: String] = [
            Self.profileIDUserInfoKey: profileID.uuidString
        ]
        if let threadURLString = thread?.webURLString {
            userInfo[Self.threadURLUserInfoKey] = threadURLString
        }
        content.userInfo = userInfo

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

    private func configureCategories() {
        guard let center else { return }

        let openThread = UNNotificationAction(
            identifier: Self.openThreadActionID,
            title: "Open on ampcode.com",
            options: [.foreground]
        )
        let viewLogs = UNNotificationAction(
            identifier: Self.viewLogsActionID,
            title: "View Logs",
            options: [.foreground]
        )

        let threadCategory = UNNotificationCategory(
            identifier: Self.threadCategoryID,
            actions: [openThread, viewLogs],
            intentIdentifiers: [],
            options: []
        )
        let runnerCategory = UNNotificationCategory(
            identifier: Self.runnerCategoryID,
            actions: [viewLogs],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([threadCategory, runnerCategory])
    }

    private func metadataBody(
        for thread: RunnerThreadDetails?,
        duration: TimeInterval?,
        fallback: String
    ) -> String {
        var parts: [String] = []
        if let project = thread?.projectDisplayName {
            parts.append(project)
        }
        if let duration {
            parts.append("Duration \(ProcessSupervisor.formattedDuration(duration))")
        }
        if let messageCount = thread?.messageCount {
            parts.append(messageCount == 1 ? "1 message" : "\(messageCount) messages")
        }
        if let id = thread?.id {
            parts.append(id)
        }
        return parts.isEmpty ? fallback : parts.joined(separator: " - ")
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.handle(response: response)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    private func handle(response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let profileID = (userInfo[Self.profileIDUserInfoKey] as? String)
            .flatMap { UUID(uuidString: $0) }
        let threadURLString = userInfo[Self.threadURLUserInfoKey] as? String

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier
            where response.notification.request.content.categoryIdentifier == Self.runnerCategoryID:
            if let profileID {
                actionHandler?(.viewLogs(profileID: profileID))
            }
        case Self.openThreadActionID, UNNotificationDefaultActionIdentifier:
            actionHandler?(.openThread(profileID: profileID, urlString: threadURLString))
        case Self.viewLogsActionID:
            if let profileID {
                actionHandler?(.viewLogs(profileID: profileID))
            }
        default:
            break
        }
    }
}
