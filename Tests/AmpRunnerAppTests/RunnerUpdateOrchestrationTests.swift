import XCTest
import Combine
import AmpRunnerCore
@testable import AmpRunner

final class RunnerUpdateOrchestrationTests: XCTestCase {
    @MainActor
    func testJoinsSharedExecutableStateWithPerProfileRunningVersions() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.latest = AmpVersion("3.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .online, active: false, running: AmpVersion("2.0.0"))
        fixture.load()

        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .restartRequired(running: AmpVersion("1.0.0")!, installed: AmpVersion("2.0.0")!))
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.second), .updateAvailable(installed: AmpVersion("2.0.0")!, latest: AmpVersion("3.0.0")!))
    }

    @MainActor
    func testInstallStateAndFailureAreJoinedByExecutable() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("1.0.0")
        fixture.installStates[fixture.path] = .installing
        fixture.load()
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .installing(installed: AmpVersion("1.0.0")))
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.second), .installing(installed: AmpVersion("1.0.0")))

        fixture.installStates[fixture.path] = .failed("no permission")
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .updateFailed(installed: AmpVersion("1.0.0"), message: "no permission"))
    }

    @MainActor
    func testAutomaticAndQueuedRestartsWaitForIdleAndNeverRestartStoppedOrIneligibleProfiles() throws {
        let fixture = try Fixture(preferences: .init(restartsUpdatedRunnersWhenIdle: true))
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .stopped, active: false, running: nil)
        fixture.load()
        fixture.coordinator.restartAllWhenIdle()
        XCTAssertEqual(fixture.restarts, [])

        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.changes.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id])
        fixture.changes.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id], "restart in flight prevents duplicates")
        XCTAssertFalse(fixture.coordinator.queuedUpdateRestartProfileIDs.contains(fixture.second.id))
    }

    @MainActor
    func testCompletedInstallAutomaticallyQueuesOnlyRunningOutdatedProfiles() throws {
        let fixture = try Fixture(preferences: .init(restartsUpdatedRunnersWhenIdle: true))
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .starting, active: false, running: AmpVersion("1.0.0"))
        fixture.load()
        fixture.installCompletions.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id])
        XCTAssertFalse(fixture.coordinator.queuedUpdateRestartProfileIDs.contains(fixture.second.id))
    }

    @MainActor
    func testRestartActionsRespectStoppedStateAndConfirmedNowRestartsAllRunningOutdatedProfiles() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .stopped, active: false, running: nil)
        fixture.load()
        fixture.coordinator.restartToUpdate(fixture.second)
        XCTAssertEqual(fixture.restarts, [])
        fixture.coordinator.restartAllNow()
        XCTAssertEqual(fixture.restarts, [fixture.first.id])
    }

    @MainActor
    func testPublishedNewRunningVersionClearsInFlightAndRestartRequirement() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.load()
        fixture.coordinator.restartToUpdate(fixture.first)
        XCTAssertTrue(fixture.coordinator.updateRestartProfileIDsInFlight.contains(fixture.first.id))
        fixture.snapshots[fixture.first.id] = .init(status: .stopped, active: false, running: nil)
        fixture.changes.send()
        XCTAssertTrue(fixture.coordinator.updateRestartProfileIDsInFlight.contains(fixture.first.id), "transient relaunch states must not permit a duplicate restart")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("2.0.0"))
        fixture.changes.send()
        XCTAssertFalse(fixture.coordinator.updateRestartProfileIDsInFlight.contains(fixture.first.id))
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .upToDate(AmpVersion("2.0.0")!))
    }

    @MainActor
    func testPreferencesLoadSaveApplyAndMalformedLoadIsNonfatal() throws {
        let suite = "RunnerUpdateOrchestrationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferencesStore = AmpUpdatePreferencesStore(defaults: defaults, key: "prefs")
        defaults.set("bad", forKey: "prefs")
        let fixture = try Fixture(preferencesStore: preferencesStore)
        XCTAssertEqual(fixture.coordinator.updatePreferences, AmpUpdatePreferences())
        XCTAssertTrue(fixture.coordinator.loadError?.contains("update preferences") == true)

        let saved = AmpUpdatePreferences(automaticallyChecksForUpdates: false, sendsUpdateNotifications: false, automaticallyInstallsUpdates: true, restartsUpdatedRunnersWhenIdle: true)
        try fixture.coordinator.saveUpdatePreferences(saved)
        XCTAssertEqual(try preferencesStore.load(), saved)
        XCTAssertEqual(fixture.appliedPreferences.last, saved)
        XCTAssertNil(fixture.coordinator.loadError)
    }
}

@MainActor
private final class Fixture {
    struct Snapshot { var status: RunnerStatus; var active: Bool; var running: AmpVersion? }
    let root: URL
    let path: String
    let first: RunnerProfile
    let second: RunnerProfile
    var coordinator: RunnerCoordinator! = nil
    var installed: [String: AmpVersion] = [:]
    var installStates: [String: AmpExecutableInstallState] = [:]
    var latest: AmpVersion?
    var snapshots: [UUID: Snapshot] = [:]
    var restarts: [UUID] = []
    var appliedPreferences: [AmpUpdatePreferences] = []
    let changes = PassthroughSubject<Void, Never>()
    let installCompletions = PassthroughSubject<Void, Never>()

    init(preferences: AmpUpdatePreferences? = nil, preferencesStore suppliedStore: AmpUpdatePreferencesStore? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("amp").path
        let firstDirectory = root.appendingPathComponent("one")
        let secondDirectory = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        first = RunnerProfile(name: "One", runnerID: "one", workingDirectoryPath: firstDirectory.path, ampExecutablePath: path)
        second = RunnerProfile(name: "Two", runnerID: "two", workingDirectoryPath: secondDirectory.path, ampExecutablePath: path)
        let profileStore = RunnerProfileStore(fileURL: root.appendingPathComponent("profiles.json"), io: FileManagerProfileStoreIO())
        _ = try profileStore.upsert(first, into: [])
        _ = try profileStore.upsert(second, into: [first])
        let preferenceStore: AmpUpdatePreferencesStore
        if let suppliedStore {
            preferenceStore = suppliedStore
        } else {
            preferenceStore = AmpUpdatePreferencesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), key: "prefs")
        }
        if let preferences { try preferenceStore.save(preferences) }
        coordinator = RunnerCoordinator(
            homeDirectoryPath: root.path,
            store: profileStore,
            pathSettingsStore: RunnerPathSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), key: "path"),
            inheritedEnvironment: [:],
            ampUpdatePreferencesStore: preferenceStore,
            updateStateSource: { [weak self] profile in
                let snapshot = self?.snapshots[profile.id]
                return RunnerUpdateStateSource(
                    status: snapshot?.status ?? .stopped,
                    hasActiveThread: snapshot?.active ?? false,
                    runningVersion: snapshot?.running,
                    installedVersion: self?.installed[self?.path ?? ""],
                    latestVersion: self?.latest,
                    installState: self?.installStates[self?.path ?? ""]
                )
            },
            restartUpdatedRunner: { [weak self] id in self?.restarts.append(id) },
            supervisorChanges: changes.eraseToAnyPublisher(),
            installCompletions: installCompletions.eraseToAnyPublisher(),
            applyUpdatePreferences: { [weak self] value in self?.appliedPreferences.append(value) }
        )
    }

    func load() { coordinator.onLaunch() }
}
