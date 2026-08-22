import XCTest
import Combine
import AmpRunnerCore
@testable import AmpRunner

final class RunnerUpdateOrchestrationTests: XCTestCase {
    @MainActor
    func testAggregateNotificationsCountExecutablesAndProfilesOncePerReleaseAndBatch() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("1.0.0")
        fixture.latest = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()
        XCTAssertEqual(fixture.updateRequests.count, 1)
        XCTAssertEqual(fixture.updateRequests.first?.body, "Update 1 Amp installation used by 2 runners.")
        fixture.coordinator.reevaluateUpdateNotifications()
        XCTAssertEqual(fixture.updateRequests.count, 1)

        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        let batch = AmpInstallBatch(completedAt: Date(), results: [
            .init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .updated(AmpVersion("2.0.0")!))
        ])
        fixture.installCompletions.send(batch)
        XCTAssertEqual(fixture.updateRequests.count, 2)
        XCTAssertEqual(fixture.updateRequests.last?.body, "2 runners need a restart: 1 idle, 1 working.")
        fixture.installCompletions.send(batch)
        XCTAssertEqual(fixture.updateRequests.count, 2)
    }

    @MainActor
    func testCompletedBatchNotifiesOnlyProfilesWhosePathsWereActuallyUpdated() throws {
        let fixture = try Fixture(sharedExecutable: false)
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.installed[fixture.secondPath] = AmpVersion("1.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()

        fixture.complete([
            .init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .updated(AmpVersion("2.0.0")!)),
            .init(path: fixture.secondPath, state: .failed("denied"), outcome: .failed)
        ])

        XCTAssertEqual(fixture.updateRequests.map(\.body), ["1 runner needs a restart: 1 idle, 0 working."])
    }

    @MainActor
    func testMixedVersionBatchEmitsOnceWhenRepresentativeVersionWasPreviouslyNotified() throws {
        let fixture = try Fixture(sharedExecutable: false)
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.installed[fixture.secondPath] = AmpVersion("1.5.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()
        fixture.complete([.init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .updated(AmpVersion("2.0.0")!))])
        let mixedBatch = AmpInstallBatch(completedAt: Date(timeIntervalSinceReferenceDate: 42), results: [
            .init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .updated(AmpVersion("2.0.0")!)),
            .init(path: fixture.secondPath, state: .succeeded(AmpVersion("1.5.0")!), outcome: .updated(AmpVersion("1.5.0")!))
        ])

        fixture.installCompletions.send(mixedBatch)
        fixture.installCompletions.send(mixedBatch)

        XCTAssertEqual(fixture.updateRequests.map(\.body), [
            "1 runner needs a restart: 1 idle, 0 working.",
            "2 runners need a restart: 1 idle, 1 working."
        ])
    }

    @MainActor
    func testDistinctBatchIDsAtSameCompletionTimeBothEmitAggregateNotifications() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()
        let completedAt = Date(timeIntervalSinceReferenceDate: 42)
        let result = AmpInstallBatch.Result(
            path: fixture.path,
            state: .succeeded(AmpVersion("2.0.0")!),
            outcome: .updated(AmpVersion("2.0.0")!)
        )

        fixture.installCompletions.send(.init(id: UUID(), completedAt: completedAt, results: [result]))
        fixture.installCompletions.send(.init(id: UUID(), completedAt: completedAt, results: [result]))

        XCTAssertEqual(fixture.updateRequests.map(\.body), [
            "2 runners need a restart: 1 idle, 1 working.",
            "2 runners need a restart: 1 idle, 1 working."
        ])
    }

    @MainActor
    func testEmptyFailedAndNoUpdateBatchesIgnoreUnrelatedPriorRestartState() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.load()

        fixture.complete([])
        fixture.complete([.init(path: fixture.path, state: .failed("denied"), outcome: .failed)])
        fixture.complete([.init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .noUpdateNeeded)])

        XCTAssertTrue(fixture.updateRequests.isEmpty)
    }

    @MainActor
    func testRestartAggregateExcludesStartingAndUsesAutomaticActionsAndWording() throws {
        let fixture = try Fixture(preferences: .init(restartsUpdatedRunnersWhenIdle: true))
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .starting, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()

        fixture.complete([.init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .updated(AmpVersion("2.0.0")!))])

        XCTAssertEqual(fixture.updateRequests.last?.body, "0 runners restarted; 1 pending until idle.")
        XCTAssertEqual(fixture.updateRequests.last?.actions, [.openUpdates])
    }

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
    func testInstallAvailabilityRequiresOutdatedConfiguredProfileAndNoInstallInProgress() throws {
        let fixture = try Fixture()
        fixture.latest = AmpVersion("2.0.0")
        fixture.load()
        XCTAssertFalse(fixture.coordinator.canInstallAvailableUpdate)

        fixture.installed[fixture.path] = AmpVersion("1.0.0")
        XCTAssertTrue(fixture.coordinator.canInstallAvailableUpdate)

        fixture.installStates[fixture.path] = .installing
        XCTAssertFalse(fixture.coordinator.canInstallAvailableUpdate)
    }

    @MainActor
    func testExplicitQueuedRestartsWaitForIdleAndNeverRestartStoppedOrIneligibleProfiles() throws {
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
    func testEnablingAutomaticIdleRestartsImmediatelyRestartsIdleAndWaitsForWorkingRunner() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()

        try fixture.coordinator.saveUpdatePreferences(.init(restartsUpdatedRunnersWhenIdle: true))
        XCTAssertEqual(fixture.restarts, [fixture.first.id])
        XCTAssertTrue(fixture.coordinator.queuedUpdateRestartProfileIDs.isEmpty, "automatic policy must not own one-shot queue entries")

        fixture.snapshots[fixture.second.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.changes.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id, fixture.second.id])
    }

    @MainActor
    func testDisablingAutomaticIdleRestartsPreventsFutureAutomaticWorkButPreservesExplicitQueue() throws {
        let fixture = try Fixture(preferences: .init(restartsUpdatedRunnersWhenIdle: true))
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()
        fixture.coordinator.restartAllWhenIdle()

        try fixture.coordinator.saveUpdatePreferences(.init(restartsUpdatedRunnersWhenIdle: false))
        XCTAssertTrue(fixture.coordinator.queuedUpdateRestartProfileIDs.contains(fixture.first.id))
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.changes.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id], "explicit one-shot request survives automatic policy changes")

        fixture.snapshots[fixture.second.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.changes.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id], "disabled automatic policy cannot schedule new work")
    }

    @MainActor
    func testCompletedInstallAutomaticallyRestartsOnlyEligibleRunningOutdatedProfiles() throws {
        let fixture = try Fixture(preferences: .init(restartsUpdatedRunnersWhenIdle: true))
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .starting, active: false, running: AmpVersion("1.0.0"))
        fixture.load()
        fixture.complete([.init(path: fixture.path, state: .succeeded(AmpVersion("2.0.0")!), outcome: .updated(AmpVersion("2.0.0")!))])
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
    func testNotificationActionsRouteToCoordinatorEffectsWithoutThreadResponses() throws {
        let fixture = try Fixture()
        fixture.installed[fixture.path] = AmpVersion("2.0.0")
        fixture.snapshots[fixture.first.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.load()

        fixture.coordinator.notifier.handleUpdateAction(.restartAllWhenIdle)
        XCTAssertEqual(fixture.coordinator.queuedUpdateRestartProfileIDs, [fixture.first.id])
        XCTAssertNil(fixture.coordinator.logViewerProfileID)

        fixture.coordinator.notifier.handleUpdateAction(.defaultOpen)
        XCTAssertEqual(fixture.coordinator.settingsPane, .updates)
        XCTAssertNil(fixture.coordinator.logViewerProfileID)
    }

    @MainActor
    func testInstallUpdateNotificationActionInstallsAllOutdatedExecutables() throws {
        var installAllCallCount = 0
        let fixture = try Fixture(installOutdatedExecutables: { installAllCallCount += 1 })

        fixture.coordinator.notifier.handleUpdateAction(.installUpdate)

        XCTAssertEqual(installAllCallCount, 1)
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

    @MainActor
    func testSaveFailurePreservesAppliedPreferences() throws {
        enum Failure: Error { case write }
        let fixture = try Fixture(
            preferences: .init(automaticallyChecksForUpdates: false),
            savePreferences: { _ in throw Failure.write }
        )
        let original = fixture.coordinator.updatePreferences
        let appliedCount = fixture.appliedPreferences.count

        XCTAssertThrowsError(try fixture.coordinator.saveUpdatePreferences(.init(restartsUpdatedRunnersWhenIdle: true)))
        XCTAssertEqual(fixture.coordinator.updatePreferences, original)
        XCTAssertEqual(fixture.appliedPreferences.count, appliedCount)
    }

    @MainActor
    func testControllerPostMutationPublicationReevaluatesAutomaticRestart() async throws {
        var reportedVersion = AmpVersion("1.0.0")!
        let controller = AmpUpdateController(executeCommand: { request in
            XCTAssertEqual(request.arguments, ["version"])
            return AmpCommandResult(exitCode: 0, stdout: Data("\(reportedVersion)\n".utf8), stderr: Data())
        })
        let fixture = try Fixture(preferences: .init(restartsUpdatedRunnersWhenIdle: true), controller: controller)
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.load()
        _ = await controller.installedVersion(for: URL(fileURLWithPath: fixture.path), environment: [:])
        reportedVersion = AmpVersion("2.0.0")!
        controller.synchronizeExecutables([])
        controller.synchronizeExecutables([.init(executableURL: URL(fileURLWithPath: fixture.path), environment: [:])])

        _ = await controller.installedVersion(for: URL(fileURLWithPath: fixture.path), environment: [:])
        XCTAssertEqual(controller.installedVersions[fixture.path], AmpVersion("2.0.0"))
        for _ in 0..<10 where fixture.restarts.isEmpty { await Task.yield() }
        XCTAssertEqual(fixture.restarts, [fixture.first.id], "reconciliation must observe the published value after mutation")
    }

    @MainActor
    func testFakeAmpEndToEndCheckInstallNotificationAndIdleRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ampURL = root.appendingPathComponent("amp")
        let versionURL = root.appendingPathComponent("version")
        let callsURL = root.appendingPathComponent("calls")
        try Data("1.0.0\n".utf8).write(to: versionURL)
        let script = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(callsURL.path)"
        case "$1" in
          version) cat "\(versionURL.path)" ;;
          update)
            test "$2" = "--porcelain" || exit 2
            printf '2.0.0\n' > "\(versionURL.path)"
            printf 'updated 2.0.0\n'
            ;;
          *) exit 3 ;;
        esac
        """
        try Data(script.utf8).write(to: ampURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ampURL.path)

        var releaseRequests = 0
        let controller = AmpUpdateController(fetchRelease: { _ in
            releaseRequests += 1
            return Data("2.0.0\n".utf8)
        })
        let fixture = try Fixture(
            preferences: .init(automaticallyChecksForUpdates: false, restartsUpdatedRunnersWhenIdle: true),
            controller: controller,
            executablePath: ampURL.path
        )
        fixture.snapshots[fixture.first.id] = .init(status: .working, active: true, running: AmpVersion("1.0.0"))
        fixture.snapshots[fixture.second.id] = .init(status: .stopped, active: false, running: nil)
        fixture.load()

        await controller.checkNow()
        _ = await controller.installedVersion(for: ampURL, environment: [:])
        fixture.coordinator.reevaluateUpdateNotifications()
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .updateAvailable(installed: AmpVersion("1.0.0")!, latest: AmpVersion("2.0.0")!))

        await controller.installOutdatedExecutables()
        let batch = try XCTUnwrap(controller.lastCompletedInstallBatch)
        fixture.coordinator.reevaluateUpdateNotifications(completedBatch: batch)
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .restartRequired(running: AmpVersion("1.0.0")!, installed: AmpVersion("2.0.0")!))
        XCTAssertTrue(fixture.restarts.isEmpty, "automatic policy must not interrupt working Amp")

        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("1.0.0"))
        fixture.changes.send()
        XCTAssertEqual(fixture.restarts, [fixture.first.id])
        fixture.snapshots[fixture.first.id] = .init(status: .online, active: false, running: AmpVersion("2.0.0"))
        fixture.changes.send()
        XCTAssertEqual(fixture.coordinator.updateState(for: fixture.first), .upToDate(AmpVersion("2.0.0")!))

        let calls = try String(contentsOf: callsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(releaseRequests, 1)
        XCTAssertEqual(calls.filter { $0 == "update --porcelain" }.count, 1)
        XCTAssertEqual(fixture.updateRequests.filter { $0.category == .restartRequired }.count, 1)
    }
}

@MainActor
private final class Fixture {
    struct Snapshot { var status: RunnerStatus; var active: Bool; var running: AmpVersion? }
    let root: URL
    let path: String
    let secondPath: String
    let first: RunnerProfile
    let second: RunnerProfile
    var coordinator: RunnerCoordinator! = nil
    var installed: [String: AmpVersion] = [:]
    var installStates: [String: AmpExecutableInstallState] = [:]
    var latest: AmpVersion?
    var snapshots: [UUID: Snapshot] = [:]
    var restarts: [UUID] = []
    var appliedPreferences: [AmpUpdatePreferences] = []
    var updateRequests: [RunnerUpdateNotificationRequest] = []
    let changes = PassthroughSubject<Void, Never>()
    let installCompletions = PassthroughSubject<AmpInstallBatch, Never>()

    init(
        preferences: AmpUpdatePreferences? = nil,
        preferencesStore suppliedStore: AmpUpdatePreferencesStore? = nil,
        controller: AmpUpdateController? = nil,
        sharedExecutable: Bool = true,
        executablePath: String? = nil,
        savePreferences: ((AmpUpdatePreferences) throws -> Void)? = nil,
        installOutdatedExecutables: (() -> Void)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = executablePath ?? root.appendingPathComponent("amp").path
        secondPath = sharedExecutable ? path : root.appendingPathComponent("amp-two").path
        let firstDirectory = root.appendingPathComponent("one")
        let secondDirectory = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        first = RunnerProfile(name: "One", runnerID: "one", workingDirectoryPath: firstDirectory.path, ampExecutablePath: path)
        second = RunnerProfile(name: "Two", runnerID: "two", workingDirectoryPath: secondDirectory.path, ampExecutablePath: secondPath)
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
        let notificationDefaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let notifier = RunnerNotifier(defaults: notificationDefaults, deliverUpdate: { [weak self] request in
            self?.updateRequests.append(request)
            return true
        })
        coordinator = RunnerCoordinator(
            homeDirectoryPath: root.path,
            store: profileStore,
            pathSettingsStore: RunnerPathSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), key: "path"),
            inheritedEnvironment: [:],
            notifier: notifier,
            ampUpdateController: controller,
            ampUpdatePreferencesStore: preferenceStore,
            updateStateSource: { [weak self] profile in
                let snapshot = self?.snapshots[profile.id]
                return RunnerUpdateStateSource(
                    status: snapshot?.status ?? .stopped,
                    hasActiveThread: snapshot?.active ?? false,
                    runningVersion: snapshot?.running,
                    installedVersion: controller?.installedVersions[profile.ampExecutablePath] ?? self?.installed[profile.ampExecutablePath],
                    latestVersion: controller?.latestVersion ?? self?.latest,
                    installState: controller?.installStates[profile.ampExecutablePath] ?? self?.installStates[self?.path ?? ""]
                )
            },
            restartUpdatedRunner: { [weak self] id in self?.restarts.append(id) },
            supervisorChanges: changes.eraseToAnyPublisher(),
            installCompletions: installCompletions.eraseToAnyPublisher(),
            applyUpdatePreferences: { [weak self] value in self?.appliedPreferences.append(value) },
            saveUpdatePreferences: savePreferences,
            installOutdatedExecutables: installOutdatedExecutables
        )
    }

    func load() { coordinator.onLaunch() }

    func complete(_ results: [AmpInstallBatch.Result]) {
        installCompletions.send(.init(completedAt: Date(), results: results))
    }
}
