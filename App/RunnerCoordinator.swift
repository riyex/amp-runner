import Foundation
import Combine
import AppKit
import AmpRunnerCore

/// An editor the menu bar asked the Settings window to open.
enum ProfileDraftRequest: Equatable {
    case none
    case new
    case sampleProject
    case edit(UUID)
    case duplicate(UUID)
}

/// Owns all profiles and their supervisors, and is the single object the UI observes.
@MainActor
final class RunnerCoordinator: ObservableObject {

    @Published private(set) var profiles: [RunnerProfile] = []
    @Published private(set) var supervisors: [UUID: ProcessSupervisor] = [:]
    @Published private(set) var loadError: String?

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

    private let store: RunnerProfileStore
    private let homeDirectoryPath: String
    private var subscriptions: [UUID: Set<AnyCancellable>] = [:]

    struct PendingStart: Identifiable {
        let id: UUID
        let profile: RunnerProfile
        let command: ResolvedRunnerCommand
    }

    init(
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        store: RunnerProfileStore? = nil,
        notifier: RunnerNotifier? = nil,
        launchAtLogin: LaunchAtLoginManager? = nil,
        bookmarks: SecurityScopedBookmarkStore? = nil
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
        self.notifier = notifier ?? RunnerNotifier()
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginManager()
        self.bookmarks = bookmarks ?? SecurityScopedBookmarkStore()
    }

    // MARK: - Launch

    func onLaunch() {
        reload()
        bookmarks.startAccessingAll(profileIDs: profiles.map(\.id))
        checkAmpSettings()
        startAutoStartProfiles()
    }

    func onTerminate() {
        for supervisor in supervisors.values where supervisor.isRunning {
            supervisor.stop()
        }
        bookmarks.stopAccessingAll()
    }

    private func reload() {
        do {
            profiles = try store.load()
            loadError = nil
        } catch {
            profiles = []
            loadError = "Could not read saved profiles: \(error.localizedDescription)"
        }
        for profile in profiles {
            supervisor(for: profile).update(profile: profile)
        }
    }

    private func startAutoStartProfiles() {
        for profile in profiles where profile.autoStart {
            // Auto-start deliberately bypasses the confirmation sheet: the user already
            // consented to this exact command by enabling auto-start on the profile.
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

        let supervisor = ProcessSupervisor(profile: profile, homeDirectoryPath: homeDirectoryPath)
        supervisors[profile.id] = supervisor

        let profileID = profile.id
        var cancellables: Set<AnyCancellable> = []

        supervisor.events
            .sink { [weak self] event in
                guard let self else { return }
                self.notifier.notify(event: event, profileName: self.name(of: profileID))
            }
            .store(in: &cancellables)

        // Process-level failures are reported independently of the log heuristics.
        supervisor.$status
            .sink { [weak self] status in
                guard let self, case .error(let message) = status else { return }
                self.notifier.notifyRunnerError(profileName: self.name(of: profileID), message: message)
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
        for supervisor in supervisors.values where supervisor.isRunning {
            supervisor.stop()
        }
    }

    // MARK: - CRUD

    func persist(_ profile: RunnerProfile) throws {
        try RunnerProfileStore.validateCandidate(profile, against: profiles)
        profiles = try store.upsert(profile, into: profiles)
        supervisor(for: profile).update(profile: profile)
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
    }

    /// A blank profile for the editor. The working directory is intentionally empty so
    /// the user must pick one through `NSOpenPanel`.
    func makeDraftProfile() -> RunnerProfile {
        RunnerProfile(
            name: "New Runner",
            runnerID: "runner-\(profiles.count + 1)",
            workingDirectoryPath: "",
            ampExecutablePath: Self.detectAmpExecutablePath() ?? ""
        )
    }

    var shouldOfferQuickStart: Bool { profiles.isEmpty }

    /// Prefilled SampleProject profile for the first-launch quick start. Still returned as a
    /// *draft* — the editor requires the user to confirm the folder via `NSOpenPanel`
    /// before it can be saved.
    func makeSampleProjectDraft() -> RunnerProfile {
        var draft = RunnerProfile.sampleProjectQuickStart(
            homeDirectoryPath: homeDirectoryPath,
            ampExecutablePath: Self.detectAmpExecutablePath() ?? ""
        )
        // Suggested path is shown in the editor, but access is not granted until the
        // user picks the folder themselves.
        draft.workingDirectoryPath = ""
        return draft
    }

    /// Suggested directory to open the folder picker at, for the SampleProject quick start.
    var sampleProjectSuggestedDirectory: URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("sampleProject", isDirectory: true)
    }

    // MARK: - Amp settings

    var ampSettingsURL: URL {
        AmpSettingsChecker.defaultSettingsURL(homeDirectoryPath: homeDirectoryPath)
    }

    func checkAmpSettings() {
        let data = try? Data(contentsOf: ampSettingsURL)
        ampSettingsResult = AmpSettingsChecker.check(settingsData: data)
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

    // MARK: - Shell helpers

    /// `which amp`, falling back to the well-known Homebrew / /usr/local locations.
    static func detectAmpExecutablePath() -> String? {
        if let found = runWhichAmp(), !found.isEmpty { return found }
        return RunnerProfile.commonAmpExecutablePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func runWhichAmp() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "amp"]
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
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

    /// Opens the runner's page on ampcode.com. The runner-id query parameter is a
    /// convenience only — ampcode.com is the source of truth for thread routing.
    func openOnAmpCode(_ profile: RunnerProfile) {
        var components = URLComponents(string: "https://ampcode.com/threads")
        let runnerID = profile.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !runnerID.isEmpty {
            components?.queryItems = [URLQueryItem(name: "runner", value: runnerID)]
        }
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
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

    /// Live preview shown in the editor and the confirmation sheet.
    func commandPreview(for profile: RunnerProfile) -> String {
        RunnerCommandBuilder.commandPreview(for: profile, homeDirectoryPath: homeDirectoryPath)
    }
}
