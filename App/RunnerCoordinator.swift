import Foundation
import Combine
import AppKit
import AmpRunnerCore

/// An editor the menu bar asked the Settings window to open.
enum ProfileDraftRequest: Equatable {
    case none
    case new
    case edit(UUID)
    case duplicate(UUID)
}

extension Notification.Name {
    static let ampRunnerOpenSettingsWindow = Notification.Name("com.riyex.amprunner.openSettingsWindow")
}

/// Owns all profiles and their supervisors, and is the single object the UI observes.
@MainActor
final class RunnerCoordinator: ObservableObject {

    @Published private(set) var profiles: [RunnerProfile] = []
    @Published private(set) var supervisors: [UUID: ProcessSupervisor] = [:]
    @Published private(set) var loadError: String?
    @Published private(set) var pathSettings: RunnerPathSettings

    /// Result of inspecting `~/.config/amp/settings.json` at launch.
    @Published private(set) var ampSettingsResult: AmpSettingsChecker.Result = .missingFile
    @Published var isAmpSettingsWarningDismissed = false

    /// Profile awaiting the start-confirmation sheet, if any.
    @Published var pendingConfirmation: PendingStart?

    /// Profile currently open in the log viewer.
    @Published var logViewerProfileID: UUID?

    /// Which pane the Settings window shows. Set by the menu before opening the window.
    @Published var settingsPane: SettingsPane = .profiles

    /// An editor the menu asked to be opened. Consumed by `ProfileListView`.
    @Published var draftRequest: ProfileDraftRequest = .none

    let notifier: RunnerNotifier
    let launchAtLogin: LaunchAtLoginManager
    let bookmarks: SecurityScopedBookmarkStore
    let ampUpdateController: AmpUpdateController

    private let store: RunnerProfileStore
    private let pathSettingsStore: RunnerPathSettingsStore
    private let homeDirectoryPath: String
    private let inheritedEnvironment: [String: String]
    private var pathSettingsLoadError: String?
    private var profileLoadError: String?
    private var subscriptions: [UUID: Set<AnyCancellable>] = [:]
    private var updateControllerSubscription: AnyCancellable?

    struct PendingStart: Identifiable {
        let id: UUID
        let profile: RunnerProfile
        let command: ResolvedRunnerCommand
    }

    init(
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        store: RunnerProfileStore? = nil,
        pathSettingsStore: RunnerPathSettingsStore? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        notifier: RunnerNotifier? = nil,
        launchAtLogin: LaunchAtLoginManager? = nil,
        bookmarks: SecurityScopedBookmarkStore? = nil,
        ampUpdateController: AmpUpdateController? = nil
    ) {
        // Defaults are constructed here, inside the (already @MainActor) initializer body,
        // rather than as parameter default-value expressions. `RunnerNotifier`,
        // `LaunchAtLoginManager`, and `SecurityScopedBookmarkStore` are themselves
        // @MainActor, and default-value expressions evaluate in a nonisolated context,
        // so constructing them as defaults would be an actor-isolation error.
        self.homeDirectoryPath = homeDirectoryPath
        self.store = store ?? RunnerProfileStore(
            fileURL: RunnerProfileStore.defaultFileURL(homeDirectoryPath: homeDirectoryPath),
            io: FileManagerProfileStoreIO()
        )
        let resolvedPathSettingsStore = pathSettingsStore ?? RunnerPathSettingsStore()
        self.pathSettingsStore = resolvedPathSettingsStore
        self.inheritedEnvironment = inheritedEnvironment
        do {
            self.pathSettings = try resolvedPathSettingsStore.load()
        } catch {
            self.pathSettings = RunnerPathSettings()
            self.pathSettingsLoadError = "Could not read PATH settings: \(error.localizedDescription)"
        }
        self.notifier = notifier ?? RunnerNotifier()
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginManager()
        self.bookmarks = bookmarks ?? SecurityScopedBookmarkStore()
        self.ampUpdateController = ampUpdateController ?? AmpUpdateController()
        recomputeLoadError()
        updateControllerSubscription = self.ampUpdateController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        self.notifier.actionHandler = { [weak self] action in
            self?.handle(notificationAction: action)
        }
    }

    // MARK: - Launch

    func onLaunch() {
        reload()
        bookmarks.startAccessingAll(profileIDs: profiles.map(\.id))
        checkAmpSettings()
        startAutoStartProfiles()
    }

    func onTerminate() {
        for supervisor in supervisors.values {
            supervisor.stop()
        }
        bookmarks.stopAccessingAll()
    }

    private func reload() {
        do {
            profiles = try store.load()
            profileLoadError = nil
        } catch {
            profiles = []
            profileLoadError = "Could not read saved profiles: \(error.localizedDescription)"
        }
        recomputeLoadError()
        for profile in profiles {
            supervisor(for: profile).update(profile: profile)
        }
        synchronizeAmpExecutables()
    }

    private func recomputeLoadError() {
        let errors = [pathSettingsLoadError, profileLoadError].compactMap { $0 }
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func startAutoStartProfiles() {
        for profile in profiles where profile.autoStart {
            // Auto-start deliberately bypasses the confirmation sheet: the user already
            // consented to this profile's resolved Amp settings by enabling auto-start.
            supervisor(for: profile).start()
        }
    }

    // MARK: - Supervisors

    @discardableResult
    func supervisor(for profile: RunnerProfile) -> ProcessSupervisor {
        if let existing = supervisors[profile.id] {
            existing.update(profile: profile)
            return existing
        }

        let supervisor = ProcessSupervisor(
            profile: profile,
            homeDirectoryPath: homeDirectoryPath,
            environmentProvider: { [weak self, fallbackEnvironment = inheritedEnvironment] in
                self?.runnerEnvironment() ?? fallbackEnvironment
            },
            versionProvider: { [weak self] command, environment in
                guard let self else { return nil }
                return await self.ampUpdateController.installedVersion(
                    for: command.executableURL,
                    environment: environment
                )
            }
        )
        supervisors[profile.id] = supervisor

        let profileID = profile.id
        var cancellables: Set<AnyCancellable> = []

        supervisor.events
            .sink { [weak self] event in
                guard let self else { return }
                self.notifier.notify(event: event, profileID: profileID, profileName: self.name(of: profileID))
            }
            .store(in: &cancellables)

        // Process-level failures are reported independently of the log heuristics.
        supervisor.$status
            .sink { [weak self] status in
                guard let self, case .error(let message) = status else { return }
                self.notifier.notifyRunnerError(profileID: profileID, profileName: self.name(of: profileID), message: message)
            }
            .store(in: &cancellables)

        // Re-publish child changes so SwiftUI redraws the menu when a status flips.
        supervisor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        subscriptions[profileID] = cancellables
        return supervisor
    }

    private func name(of profileID: UUID) -> String {
        profiles.first { $0.id == profileID }?.name ?? "Runner"
    }

    func status(for profile: RunnerProfile) -> RunnerStatus {
        supervisors[profile.id]?.status ?? .stopped
    }

    func logLines(for profileID: UUID) -> [String] {
        supervisors[profileID]?.logLines ?? []
    }

    func threadSummary(for profile: RunnerProfile) -> String? {
        supervisors[profile.id]?.threadSummary
    }

    func threadURLString(for profile: RunnerProfile) -> String? {
        supervisors[profile.id]?.threadURLString
    }

    // MARK: - Start / stop

    /// Entry point for every user-initiated start. Honours `confirmBeforeStart`, which
    /// defaults to `true`; the "don't ask again" opt-out is a per-profile setting.
    func requestStart(_ profile: RunnerProfile) {
        guard profile.confirmBeforeStart else {
            supervisor(for: profile).start()
            return
        }
        do {
            let command = try RunnerCommandBuilder.resolve(
                profile: profile,
                homeDirectoryPath: homeDirectoryPath
            )
            pendingConfirmation = PendingStart(id: profile.id, profile: profile, command: command)
        } catch {
            loadError = "\(error)"
        }
    }

    /// Called by the confirmation sheet's Start button.
    func confirmPendingStart(rememberChoice: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil

        var profile = pending.profile
        if rememberChoice {
            profile.confirmBeforeStart = false
            try? persist(profile)
        }
        supervisor(for: profile).start()
    }

    func cancelPendingStart() {
        pendingConfirmation = nil
    }

    func stop(_ profile: RunnerProfile) {
        supervisors[profile.id]?.stop()
    }

    func restart(_ profile: RunnerProfile) {
        guard let supervisor = supervisors[profile.id], supervisor.isRunning else {
            requestStart(profile)
            return
        }
        supervisor.restart()
    }

    func stopAll() {
        for supervisor in supervisors.values {
            supervisor.stop()
        }
    }

    // MARK: - Runner PATH

    func savePathDirectories(_ directories: [String]) throws {
        let settings = RunnerPathSettings(userDirectories: directories)
        try pathSettingsStore.save(settings)
        pathSettings = settings
        pathSettingsLoadError = nil
        recomputeLoadError()
        synchronizeAmpExecutables()
    }

    func resolvedRunnerPath(for directories: [String]? = nil) -> ResolvedRunnerPath {
        RunnerPathResolver.resolve(
            settings: RunnerPathSettings(userDirectories: directories ?? pathSettings.userDirectories),
            inheritedPath: inheritedEnvironment["PATH"],
            homeDirectoryPath: homeDirectoryPath,
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        )
    }

    func runnerEnvironment() -> [String: String] {
        var environment = inheritedEnvironment
        environment["PATH"] = resolvedRunnerPath().path
        return environment
    }

    // MARK: - CRUD

    func persist(_ profile: RunnerProfile) throws {
        try RunnerProfileStore.validateCandidate(profile, against: profiles)
        profiles = try store.upsert(profile, into: profiles)
        supervisor(for: profile).update(profile: profile)
        synchronizeAmpExecutables()
    }

    /// Returns an unsaved copy for the editor. Nothing is persisted until the user picks
    /// a working directory, because the duplicate must not inherit the original's —
    /// one profile, one isolated directory.
    func makeDuplicateDraft(of profile: RunnerProfile) -> RunnerProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) copy"
        copy.runnerID = "\(profile.runnerID)-copy"
        copy.arguments = RunnerProfile.defaultArguments(runnerID: copy.runnerID)
        copy.autoStart = false
        copy.confirmBeforeStart = true
        copy.workingDirectoryPath = ""
        return copy
    }

    func delete(_ profile: RunnerProfile) throws {
        supervisors[profile.id]?.stop()
        supervisors.removeValue(forKey: profile.id)
        subscriptions.removeValue(forKey: profile.id)
        bookmarks.removeBookmark(profileID: profile.id)
        profiles = try store.delete(id: profile.id, from: profiles)
        synchronizeAmpExecutables()
    }

    private func synchronizeAmpExecutables() {
        let registrations = profiles.compactMap { profile -> AmpExecutableRegistration? in
            guard let command = try? RunnerCommandBuilder.resolve(
                profile: profile,
                homeDirectoryPath: homeDirectoryPath
            ) else { return nil }
            return AmpExecutableRegistration(executableURL: command.executableURL)
        }
        ampUpdateController.synchronizeExecutables(registrations)
    }

    /// A blank profile for the editor. The working directory is intentionally empty so
    /// the user must pick one through `NSOpenPanel`.
    func makeDraftProfile() -> RunnerProfile {
        RunnerProfile(
            name: "New Runner",
            runnerID: "runner-\(profiles.count + 1)",
            workingDirectoryPath: "",
            ampExecutablePath: Self.detectAmpExecutablePath(homeDirectoryPath: homeDirectoryPath) ?? ""
        )
    }

    // MARK: - Amp settings

    var ampSettingsURL: URL {
        AmpSettingsChecker.defaultSettingsURL(homeDirectoryPath: homeDirectoryPath)
    }

    @discardableResult
    func checkAmpSettings() -> AmpSettingsChecker.Result {
        let data = try? Data(contentsOf: ampSettingsURL)
        let result = AmpSettingsChecker.check(settingsData: data)
        ampSettingsResult = result
        if result.needsAttention {
            isAmpSettingsWarningDismissed = false
        }
        return result
    }

    /// Rewrites `~/.config/amp/settings.json` with remote thread creation enabled,
    /// preserving every other key. Refuses to touch an unparseable file.
    func enableRemoteThreadCreation() {
        let url = ampSettingsURL
        let existing = try? Data(contentsOf: url)
        do {
            let merged = try AmpSettingsChecker.settingsEnablingRemoteThreadCreation(existing: existing)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try merged.write(to: url, options: .atomic)
        } catch {
            loadError = "Could not update \(url.path): \(error.localizedDescription)"
        }
        checkAmpSettings()
    }

    // MARK: - Executable detection

    /// Checks installer-owned locations, the app's inherited `PATH`, then other common
    /// install locations.
    ///
    /// This deliberately avoids sourcing shell startup files. Those files are
    /// shell-specific and may run arbitrary interactive startup code; the final resolved
    /// executable path should be deterministic and user-visible instead.
    static func detectAmpExecutablePath(
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        AmpExecutableDetector.detect(
            environmentPath: environment["PATH"],
            ampHomePath: environment["AMP_HOME"],
            homeDirectoryPath: homeDirectoryPath
        ) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // MARK: - Opening things

    func revealWorkingDirectoryInFinder(_ profile: RunnerProfile) {
        let path = RunnerCommandBuilder.expand(
            path: profile.workingDirectoryPath,
            homeDirectoryPath: homeDirectoryPath
        )
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openWorkingDirectoryInTerminal(_ profile: RunnerProfile) {
        let path = RunnerCommandBuilder.expand(
            path: profile.workingDirectoryPath,
            homeDirectoryPath: homeDirectoryPath
        )
        guard !path.isEmpty,
              let terminal = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal"
              )
        else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)],
            withApplicationAt: terminal,
            configuration: configuration
        )
    }

    /// Opens the current/last thread when known; otherwise falls back to the runner page.
    func openOnAmpCode(_ profile: RunnerProfile) {
        if let threadURLString = threadURLString(for: profile),
           openURLString(threadURLString) {
            return
        }
        openRunnerOnAmpCode(profile)
    }

    /// Opens the runner's page on ampcode.com. The runner-id query parameter is a
    /// convenience only — ampcode.com is the source of truth for thread routing.
    func openRunnerOnAmpCode(_ profile: RunnerProfile) {
        var components = URLComponents(string: "https://ampcode.com/threads")
        let runnerID = profile.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !runnerID.isEmpty {
            components?.queryItems = [URLQueryItem(name: "runner", value: runnerID)]
        }
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openLogs(profileID: UUID) {
        logViewerProfileID = profileID
        settingsPane = .logs
        NotificationCenter.default.post(name: .ampRunnerOpenSettingsWindow, object: nil)
        SettingsWindowOpener.activateApp()
    }

    @discardableResult
    func openURLString(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    func revealLogFileInFinder(_ profileID: UUID) {
        let url = ProcessSupervisor.logFileURL(
            profileID: profileID,
            homeDirectoryPath: homeDirectoryPath
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Terminal equivalent shown in the editor and copied from the menu.
    func commandPreview(for profile: RunnerProfile) -> String {
        RunnerCommandBuilder.commandPreview(for: profile, homeDirectoryPath: homeDirectoryPath)
    }

    private func handle(notificationAction action: RunnerNotificationAction) {
        switch action {
        case .openThread(let profileID, let urlString):
            if let urlString, openURLString(urlString) {
                return
            }
            if let profileID,
               let profile = profiles.first(where: { $0.id == profileID }) {
                openRunnerOnAmpCode(profile)
                return
            }
            _ = openURLString("https://ampcode.com/threads")

        case .viewLogs(let profileID):
            openLogs(profileID: profileID)
        }
    }
}
