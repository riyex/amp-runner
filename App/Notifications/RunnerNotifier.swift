import Foundation
import UserNotifications
import AmpRunnerCore

enum RunnerNotificationAction: Equatable {
    case openThread(profileID: UUID?, urlString: String?)
    case viewLogs(profileID: UUID)
    case installUpdate
    case restartAllWhenIdle
    case openUpdates
}

enum RunnerUpdateNotificationCategory: Equatable {
    case updateAvailable
    case restartRequired
}

enum RunnerUpdateNotificationContentAction: Equatable {
    case installUpdate
    case restartAllWhenIdle
    case openUpdates
}

struct RunnerUpdateNotificationRequest: Equatable {
    let title: String
    let body: String
    let category: RunnerUpdateNotificationCategory
    let actions: [RunnerUpdateNotificationContentAction]
}

enum RunnerUpdateNotificationBuilder {
    static func build(_ event: AmpUpdateNotificationEvent) -> RunnerUpdateNotificationRequest {
        switch event {
        case let .updateAvailable(version, executableCount, runnerCount):
            return RunnerUpdateNotificationRequest(
                title: "Amp \(version) is available",
                body: "Update \(executableCount) Amp \(executableCount == 1 ? "installation" : "installations") used by \(runnerCount) \(runnerCount == 1 ? "runner" : "runners").",
                category: .updateAvailable,
                actions: [.installUpdate, .openUpdates]
            )
        case let .restartRequired(_, runnerCount, idleCount, workingCount, automaticallyRestartsWhenIdle):
            let body = automaticallyRestartsWhenIdle
                ? "\(idleCount) idle \(idleCount == 1 ? "runner" : "runners") will restart now; \(workingCount) working \(workingCount == 1 ? "runner" : "runners") will restart when idle."
                : "\(runnerCount) \(runnerCount == 1 ? "runner needs" : "runners need") a restart: \(idleCount) idle, \(workingCount) working."
            return RunnerUpdateNotificationRequest(
                title: "Restart runners to finish updating Amp",
                body: body,
                category: .restartRequired,
                actions: automaticallyRestartsWhenIdle ? [.openUpdates] : [.restartAllWhenIdle, .openUpdates]
            )
        }
    }
}

enum RunnerUpdateNotificationResponseAction {
    case installUpdate
    case restartAllWhenIdle
    case openUpdates
    case defaultOpen
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
    private static let updateAvailableCategoryID = "com.riyex.amprunner.notification.updateAvailable"
    private static let restartRequiredCategoryID = "com.riyex.amprunner.notification.restartRequired"
    private static let automaticRestartRequiredCategoryID = "com.riyex.amprunner.notification.restartRequiredAutomatic"
    private static let installUpdateActionID = "com.riyex.amprunner.notification.action.installUpdate"
    private static let restartAllWhenIdleActionID = "com.riyex.amprunner.notification.action.restartAllWhenIdle"
    private static let openUpdatesActionID = "com.riyex.amprunner.notification.action.openUpdates"
    private static let lastUpdateAvailableVersionKey = "com.riyex.amprunner.notification.lastUpdateAvailableVersion"
    private static let lastRestartRequiredVersionKey = "com.riyex.amprunner.notification.lastRestartRequiredVersion"
    private static let lastRestartRequiredBatchIdentityKey = "com.riyex.amprunner.notification.lastRestartRequiredBatchIdentity"
    private static let profileIDUserInfoKey = "profileID"
    private static let threadURLUserInfoKey = "threadURL"

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    private let deliverUpdate: ((RunnerUpdateNotificationRequest) -> Bool)?
    private var authorizationRequested = false
    private var isAuthorized = false

    init(
        defaults: UserDefaults = .standard,
        deliverUpdate: ((RunnerUpdateNotificationRequest) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.deliverUpdate = deliverUpdate
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        // `current()` traps in unbundled contexts (e.g. previews / command-line runs);
        // guarding keeps the rest of the app usable there.
        self.center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
        configureCategories()
    }

    func notifyUpdates(input: AmpUpdateNotificationInput, enabled: Bool) {
        let ledger = AmpUpdateNotificationLedger(
            lastUpdateAvailableVersion: defaults.string(forKey: Self.lastUpdateAvailableVersionKey).flatMap(AmpVersion.init),
            lastRestartRequiredVersion: defaults.string(forKey: Self.lastRestartRequiredVersionKey).flatMap(AmpVersion.init),
            lastRestartRequiredBatchIdentity: defaults.string(forKey: Self.lastRestartRequiredBatchIdentityKey)
        )
        let result = AmpUpdateNotificationPolicy.evaluate(input: input, notificationsEnabled: enabled, ledger: ledger)
        if result.ledger.lastUpdateAvailableVersion != ledger.lastUpdateAvailableVersion,
           let version = result.ledger.lastUpdateAvailableVersion {
            defaults.set(version.description, forKey: Self.lastUpdateAvailableVersionKey)
        }
        if result.ledger.lastRestartRequiredVersion != ledger.lastRestartRequiredVersion,
           let version = result.ledger.lastRestartRequiredVersion {
            defaults.set(version.description, forKey: Self.lastRestartRequiredVersionKey)
        }
        if result.ledger.lastRestartRequiredBatchIdentity != ledger.lastRestartRequiredBatchIdentity,
           let identity = result.ledger.lastRestartRequiredBatchIdentity {
            defaults.set(identity, forKey: Self.lastRestartRequiredBatchIdentityKey)
        }
        for event in result.events {
            let request = RunnerUpdateNotificationBuilder.build(event)
            if let deliverUpdate {
                _ = deliverUpdate(request)
            } else {
                Task { await post(update: request) }
            }
        }
    }

    func handleUpdateAction(_ action: RunnerUpdateNotificationResponseAction) {
        switch action {
        case .installUpdate: actionHandler?(.installUpdate)
        case .restartAllWhenIdle: actionHandler?(.restartAllWhenIdle)
        case .openUpdates, .defaultOpen: actionHandler?(.openUpdates)
        }
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

    private func post(update request: RunnerUpdateNotificationRequest) async {
        guard let center, await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = String(request.body.prefix(400))
        if request.category == .updateAvailable {
            content.categoryIdentifier = Self.updateAvailableCategoryID
        } else if request.actions.contains(.restartAllWhenIdle) {
            content.categoryIdentifier = Self.restartRequiredCategoryID
        } else {
            content.categoryIdentifier = Self.automaticRestartRequiredCategoryID
        }
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            NSLog("AmpRunner: failed to post update notification: \(error)")
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
        let installUpdate = UNNotificationAction(identifier: Self.installUpdateActionID, title: "Install Update", options: [.foreground])
        let restartWhenIdle = UNNotificationAction(identifier: Self.restartAllWhenIdleActionID, title: "Restart All When Idle", options: [.foreground])
        let openUpdates = UNNotificationAction(identifier: Self.openUpdatesActionID, title: "Open Updates", options: [.foreground])
        let updateCategory = UNNotificationCategory(identifier: Self.updateAvailableCategoryID, actions: [installUpdate, openUpdates], intentIdentifiers: [], options: [])
        let restartCategory = UNNotificationCategory(identifier: Self.restartRequiredCategoryID, actions: [restartWhenIdle, openUpdates], intentIdentifiers: [], options: [])
        let automaticRestartCategory = UNNotificationCategory(identifier: Self.automaticRestartRequiredCategoryID, actions: [openUpdates], intentIdentifiers: [], options: [])
        center.setNotificationCategories([threadCategory, runnerCategory, updateCategory, restartCategory, automaticRestartCategory])
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
        case Self.installUpdateActionID:
            handleUpdateAction(.installUpdate)
        case Self.restartAllWhenIdleActionID:
            handleUpdateAction(.restartAllWhenIdle)
        case Self.openUpdatesActionID:
            handleUpdateAction(.openUpdates)
        case UNNotificationDefaultActionIdentifier
            where response.notification.request.content.categoryIdentifier == Self.updateAvailableCategoryID
                || response.notification.request.content.categoryIdentifier == Self.restartRequiredCategoryID
                || response.notification.request.content.categoryIdentifier == Self.automaticRestartRequiredCategoryID:
            handleUpdateAction(.defaultOpen)
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
