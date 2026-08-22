import XCTest
import AmpRunnerCore
@testable import AmpRunner

final class AmpUpdateControllerTests: XCTestCase {
    @MainActor
    func testRegistrationAndNewLatestEventDriveDeduplicatedProbes() async {
        let commands = GatedCommands(results: ["1.0.0\n", "1.1.0\n"])
        let url = URL(fileURLWithPath: "/tmp/amp")
        var identity = AmpExecutableIdentity(modificationDate: nil, fileSize: 1, fileIdentifier: "old")
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await commands.execute($0) },
            readIdentity: { _ in identity }
        )

        controller.synchronizeExecutables([
            .init(executableURL: url, environment: [:]),
            .init(executableURL: url, environment: [:])
        ])
        await commands.waitForRequestCount(1)
        await commands.resume(at: 0)
        await waitUntil { controller.installedVersions[url.path] == AmpVersion("1.0.0") }

        identity.fileIdentifier = "new"
        await controller.checkNow()
        await commands.waitForRequestCount(2)
        await commands.resume(at: 1)
        await waitUntil { controller.installedVersions[url.path] == AmpVersion("1.1.0") }

        let arguments = await commands.recordedRequests.map(\.arguments)
        XCTAssertEqual(arguments, [["version"], ["version"]])
    }

    @MainActor
    func testHourlyCheckReprobesWhenExecutableIdentityChangesWithoutNewRelease() async {
        var identity = AmpExecutableIdentity(modificationDate: nil, fileSize: 1, fileIdentifier: "old")
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("2.0.0\n".utf8), stderr: Data())
        ])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await recorder.execute($0) },
            readIdentity: { _ in identity }
        )

        await controller.checkNow()
        controller.synchronizeExecutables([.init(executableURL: url)])
        _ = await controller.installedVersion(for: url)
        identity.fileIdentifier = "new"

        await controller.checkNow()
        await waitUntil { controller.installedVersions[url.path] == AmpVersion("2.0.0") }

        let arguments = await recorder.requests.map(\.arguments)
        XCTAssertEqual(arguments, [["version"], ["version"]])
    }

    @MainActor
    func testNewReleaseReprobesEvenWhenExecutableIdentityIsUnchanged() async {
        var releases = [Data("2.0.0".utf8), Data("3.0.0".utf8)]
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data())
        ])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(
            fetchRelease: { _ in releases.removeFirst() },
            executeCommand: { try await recorder.execute($0) },
            readIdentity: { _ in AmpExecutableIdentity(modificationDate: nil, fileSize: 1, fileIdentifier: "same") }
        )

        await controller.checkNow()
        controller.synchronizeExecutables([.init(executableURL: url)])
        _ = await controller.installedVersion(for: url)

        await controller.checkNow()
        for _ in 0..<100 where await recorder.requests.count < 2 { await Task.yield() }

        let arguments = await recorder.requests.map(\.arguments)
        XCTAssertEqual(arguments, [["version"], ["version"]])
    }

    @MainActor
    func testConcurrentChecksCoalesceAndCancellationInvalidatesUncooperativeCompletion() async {
        let fetches = GatedFetches(values: ["2.0.0", "3.0.0"])
        let controller = AmpUpdateController(fetchRelease: { try await fetches.fetch($0) })

        async let first: Void = controller.checkNow()
        await fetches.waitForRequestCount(1)
        async let second: Void = controller.checkNow()
        await Task.yield()
        let requestCount = await fetches.requestCount
        XCTAssertEqual(requestCount, 1)
        await fetches.resume(at: 0)
        _ = await (first, second)
        XCTAssertEqual(controller.latestVersion, AmpVersion("2.0.0"))

        let stale = Task { await controller.checkNow() }
        await fetches.waitForRequestCount(2)
        controller.cancel()
        await fetches.resume(at: 1)
        await stale.value
        XCTAssertEqual(controller.latestVersion, AmpVersion("2.0.0"))
        XCTAssertEqual(controller.checkState, .idle)
    }

    @MainActor
    func testScheduleUsesOneTaskThreeSecondThenHourlySleepsAndDisableCancelsIt() async {
        let sleeper = SleepRecorder()
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("1.0.0".utf8) },
            sleep: { try await sleeper.sleep($0) }
        )

        controller.setAutomaticChecksEnabled(true)
        controller.setAutomaticChecksEnabled(true)
        await sleeper.waitForCallCount(1)
        let initialIntervals = await sleeper.intervals
        XCTAssertEqual(initialIntervals, [3])

        await sleeper.resumeNext()
        await sleeper.waitForCallCount(2)
        let recurringIntervals = await sleeper.intervals
        XCTAssertEqual(recurringIntervals, [3, 3_600])

        controller.setAutomaticChecksEnabled(false)
        await sleeper.waitForCancellation()
        let cancellationCount = await sleeper.cancellationCount
        XCTAssertEqual(cancellationCount, 1)

        await controller.checkNow()
        XCTAssertEqual(controller.latestVersion, AmpVersion("1.0.0"))
    }

    @MainActor
    func testCheckUsesProductionRequestAndPreservesLatestAcrossBoundedFailure() async {
        var requests: [URLRequest] = []
        var responses = [Result<Data, Error>](
            arrayLiteral: .success(Data("1.2.3\n".utf8)), .failure(TestError.message(String(repeating: "x", count: 2_000)))
        )
        let controller = AmpUpdateController(fetchRelease: { request in
            requests.append(request)
            return try responses.removeFirst().get()
        })

        await controller.checkNow()
        XCTAssertEqual(controller.latestVersion, AmpVersion("1.2.3"))
        XCTAssertNotNil(controller.lastCheckedAt)
        XCTAssertNil(controller.checkError)
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://static.ampcode.com/cli/cli-version.txt")
        XCTAssertEqual(requests.first?.timeoutInterval, 5)
        XCTAssertEqual(requests.first?.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)

        await controller.checkNow()
        XCTAssertEqual(controller.latestVersion, AmpVersion("1.2.3"))
        XCTAssertLessThanOrEqual(controller.checkError?.count ?? .max, 512)
    }

    @MainActor
    func testMalformedCheckFailsAndLaterSuccessClearsError() async {
        var values = [Data("not a version".utf8), Data("2.0.0".utf8)]
        let controller = AmpUpdateController(fetchRelease: { _ in values.removeFirst() })
        await controller.checkNow()
        XCTAssertNil(controller.latestVersion)
        XCTAssertNotNil(controller.checkError)
        await controller.checkNow()
        XCTAssertEqual(controller.latestVersion, AmpVersion("2.0.0"))
        XCTAssertNil(controller.checkError)
    }

    @MainActor
    func testRegistrationStandardizesAndDeduplicatesPathsAndConcurrentProbes() async {
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.4.0 (abc)\n".utf8), stderr: Data())
        ])
        let controller = AmpUpdateController(executeCommand: { request in
            try await recorder.execute(request)
        }, readIdentity: { _ in AmpExecutableIdentity(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 10, fileIdentifier: "7") })
        controller.synchronizeExecutables([
            AmpExecutableRegistration(executableURL: URL(fileURLWithPath: "/tmp/bin/../bin/amp")),
            AmpExecutableRegistration(executableURL: URL(fileURLWithPath: "/tmp/bin/amp"))
        ])

        async let first = controller.installedVersion(for: URL(fileURLWithPath: "/tmp/bin/amp"))
        async let second = controller.installedVersion(for: URL(fileURLWithPath: "/tmp/bin/../bin/amp"))
        let versions = await [first, second]
        XCTAssertEqual(versions, [AmpVersion("1.4.0"), AmpVersion("1.4.0")])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.arguments, ["version"])
        XCTAssertEqual(controller.registeredExecutableURLs.count, 1)
    }

    @MainActor
    func testIdentityChangePermitsAReprobeAndUnchangedLatestDoesNotDuplicateIt() async {
        var identity = AmpExecutableIdentity(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 10, fileIdentifier: "7")
        let recorder = CommandRecorder(results: (1...3).map {
            AmpCommandResult(exitCode: 0, stdout: Data("1.\($0).0\n".utf8), stderr: Data())
        })
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("9.0.0".utf8) },
            executeCommand: { try await recorder.execute($0) },
            readIdentity: { _ in identity }
        )
        let url = URL(fileURLWithPath: "/tmp/amp")
        var observed = await controller.installedVersion(for: url)
        XCTAssertEqual(observed, AmpVersion("1.1.0"))
        observed = await controller.installedVersion(for: url)
        XCTAssertEqual(observed, AmpVersion("1.1.0"))
        identity.fileSize = 11
        observed = await controller.installedVersion(for: url)
        XCTAssertEqual(observed, AmpVersion("1.2.0"))
        await controller.checkNow()
        observed = await controller.installedVersion(for: url)
        XCTAssertEqual(observed, AmpVersion("1.2.0"))
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testStaleProbeCannotPublishAfterIdentityChanges() async {
        var identity = AmpExecutableIdentity(modificationDate: nil, fileSize: 1, fileIdentifier: "old")
        let commands = GatedCommands(results: ["1.0.0\n", "2.0.0\n"])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(
            executeCommand: { try await commands.execute($0) },
            readIdentity: { _ in identity }
        )
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: url)])

        let oldProbe = Task { await controller.installedVersion(for: url) }
        await commands.waitForRequestCount(1)
        identity.fileIdentifier = "new"
        let newProbe = Task { await controller.installedVersion(for: url) }
        await commands.waitForRequestCount(2)
        await commands.resume(at: 1)
        let newVersion = await newProbe.value
        XCTAssertEqual(newVersion, AmpVersion("2.0.0"))
        await commands.resume(at: 0)
        _ = await oldProbe.value

        XCTAssertEqual(controller.installedVersions[url.path], AmpVersion("2.0.0"))
        let requestCount = await commands.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testRemovedProbeCannotRepopulatePublishedState() async {
        let commands = GatedCommands(results: ["1.0.0\n"])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(executeCommand: { try await commands.execute($0) })
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: url)])
        let probe = Task { await controller.installedVersion(for: url) }
        await commands.waitForRequestCount(1)
        controller.synchronizeExecutables([])
        await commands.resume(at: 0)
        _ = await probe.value
        XCTAssertNil(controller.installedVersions[url.path])
        XCTAssertNil(controller.probeErrors[url.path])
    }

    @MainActor
    func testInstallProbesThenUpdatesOutdatedPathsSequentiallyWithoutPostProbe() async {
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("updated 2.0.0\n".utf8), stderr: Data())
        ])
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await recorder.execute($0) }
        )
        let url = URL(fileURLWithPath: "/tmp/amp")
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: url)])
        await controller.checkNow()
        await controller.installOutdatedExecutables()

        let arguments = await recorder.requests.map(\.arguments)
        XCTAssertEqual(arguments, [["version"], ["update", "--porcelain"]])
        XCTAssertEqual(controller.installedVersions[url.standardizedFileURL.path], AmpVersion("2.0.0"))
        XCTAssertEqual(controller.lastCompletedInstallBatch?.results.count, 1)
        XCTAssertEqual(controller.lastCompletedInstallBatch?.results.first?.outcome, .updated(AmpVersion("2.0.0")!))
        XCTAssertEqual(controller.installStates[url.standardizedFileURL.path], .succeeded(AmpVersion("2.0.0")!))
    }

    @MainActor
    func testNoUpdateNeededPreservesProbeAndAutomaticAttemptIsDeduplicated() async {
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("no update needed\n".utf8), stderr: Data())
        ])
        let controller = AmpUpdateController(fetchRelease: { _ in Data("2.0.0".utf8) }, executeCommand: { try await recorder.execute($0) })
        let url = URL(fileURLWithPath: "/tmp/amp")
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: url)])
        await controller.checkNow()
        await controller.installOutdatedExecutables(automatic: true)
        XCTAssertEqual(controller.installedVersions[url.standardizedFileURL.path], AmpVersion("1.0.0"))
        XCTAssertEqual(controller.lastCompletedInstallBatch?.results.first?.outcome, .noUpdateNeeded)
        await controller.installOutdatedExecutables(automatic: true)
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testEnvironmentChangeDuringUpdatePublishesAuthoritativeVersionWithoutCurrentMetadataOrStaleState() async {
        let commands = GatedCommands(results: ["1.0.0\n", "updated 2.0.0\n", "2.0.0\n"])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let oldEnvironment = ["PATH": "/old/bin"]
        let newEnvironment = ["PATH": "/new/bin"]
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await commands.execute($0) }
        )
        controller.synchronizeExecutables([
            AmpExecutableRegistration(executableURL: url, environment: oldEnvironment)
        ])
        await controller.checkNow()

        let install = Task { await controller.installOutdatedExecutables() }
        await commands.waitForRequestCount(1)
        await commands.resume(at: 0)
        await commands.waitForRequestCount(2)
        controller.synchronizeExecutables([])
        controller.synchronizeExecutables([
            AmpExecutableRegistration(executableURL: url, environment: newEnvironment)
        ])
        await commands.resume(at: 1)
        await install.value

        XCTAssertEqual(controller.installedVersions[url.path], AmpVersion("2.0.0"))
        XCTAssertNil(controller.installStates[url.path])

        let reprobe = Task { await controller.installedVersion(for: url, environment: newEnvironment) }
        await commands.waitForRequestCount(3)
        let requests = await commands.recordedRequests
        XCTAssertEqual(requests.map(\.arguments), [["version"], ["update", "--porcelain"], ["version"]])
        XCTAssertEqual(requests[2].environment, newEnvironment)
        await commands.resume(at: 2)
        let reprobedVersion = await reprobe.value
        XCTAssertEqual(reprobedVersion, AmpVersion("2.0.0"))
    }

    @MainActor
    func testFullyInvalidatedInstallBatchDoesNotReplaceLastLegitimateCompletion() async {
        let commands = GatedCommands(results: [
            "1.0.0\n", "updated 2.0.0\n",
            "1.0.0\n", "updated 2.0.0\n"
        ])
        let firstURL = URL(fileURLWithPath: "/tmp/first/amp")
        let staleURL = URL(fileURLWithPath: "/tmp/stale/amp")
        let oldEnvironment = ["PATH": "/old/bin"]
        let newEnvironment = ["PATH": "/new/bin"]
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await commands.execute($0) }
        )
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: firstURL)])
        await controller.checkNow()

        let firstInstall = Task { await controller.installOutdatedExecutables() }
        await commands.waitForRequestCount(1)
        await commands.resume(at: 0)
        await commands.waitForRequestCount(2)
        await commands.resume(at: 1)
        await firstInstall.value
        let legitimateBatch = controller.lastCompletedInstallBatch
        XCTAssertEqual(legitimateBatch?.results.map(\.path), [firstURL.path])

        controller.synchronizeExecutables([
            AmpExecutableRegistration(executableURL: staleURL, environment: oldEnvironment)
        ])
        let staleInstall = Task { await controller.installOutdatedExecutables() }
        await commands.waitForRequestCount(3)
        await commands.resume(at: 2)
        await commands.waitForRequestCount(4)
        controller.synchronizeExecutables([
            AmpExecutableRegistration(executableURL: staleURL, environment: newEnvironment)
        ])
        await commands.resume(at: 3)
        await staleInstall.value

        XCTAssertEqual(controller.lastCompletedInstallBatch, legitimateBatch)
    }

    @MainActor
    func testConcurrentInstallCallsCoalesceAndReserveAutomaticAttemptBeforeProbeSuspends() async {
        let commands = GatedCommands(results: ["1.0.0\n", "updated 2.0.0\n"])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await commands.execute($0) }
        )
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: url)])
        await controller.checkNow()

        async let first: Void = controller.installOutdatedExecutables(automatic: true)
        await commands.waitForRequestCount(1)
        async let second: Void = controller.installOutdatedExecutables(automatic: true)
        await Task.yield()
        var requestCount = await commands.requestCount
        XCTAssertEqual(requestCount, 1)
        await commands.resume(at: 0)
        await commands.waitForRequestCount(2)
        await commands.resume(at: 1)
        _ = await (first, second)
        requestCount = await commands.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testManualRetryAlwaysFreshlyProbesAndPreservesVersionOnFailure() async {
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 1, stdout: Data(), stderr: Data("failed".utf8)),
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("no update needed\n".utf8), stderr: Data())
        ])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await recorder.execute($0) }
        )
        controller.synchronizeExecutables([AmpExecutableRegistration(executableURL: url)])
        await controller.checkNow()
        await controller.installOutdatedExecutables()
        XCTAssertEqual(controller.installedVersions[url.path], AmpVersion("1.0.0"))
        XCTAssertEqual(controller.installStates[url.path], .failed("failed"))

        await controller.installOutdatedExecutables()
        let arguments = await recorder.requests.map(\.arguments)
        XCTAssertEqual(arguments, [
            ["version"], ["update", "--porcelain"],
            ["version"], ["update", "--porcelain"]
        ])
        XCTAssertEqual(controller.installedVersions[url.path], AmpVersion("1.0.0"))
    }

    @MainActor
    func testExternalUpdateClearsObsoleteInstallFailure() async {
        var identity = AmpExecutableIdentity(modificationDate: nil, fileSize: 1, fileIdentifier: "old")
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 1, stdout: Data(), stderr: Data("failed".utf8)),
            AmpCommandResult(exitCode: 0, stdout: Data("2.0.0\n".utf8), stderr: Data())
        ])
        let url = URL(fileURLWithPath: "/tmp/amp")
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await recorder.execute($0) },
            readIdentity: { _ in identity }
        )
        controller.synchronizeExecutables([.init(executableURL: url)])
        _ = await controller.installedVersion(for: url)
        await controller.checkNow()
        await controller.installOutdatedExecutables()
        XCTAssertEqual(controller.installStates[url.path], .failed("failed"))

        identity.fileIdentifier = "new"
        _ = await controller.installedVersion(for: url)

        XCTAssertEqual(controller.installedVersions[url.path], AmpVersion("2.0.0"))
        XCTAssertNil(controller.installStates[url.path])
    }

    @MainActor
    func testDuplicateRegistrationsInstallDistinctPathsOnceInRegistrationOrder() async {
        let recorder = CommandRecorder(results: [
            AmpCommandResult(exitCode: 0, stdout: Data("1.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("updated 2.0.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("1.5.0\n".utf8), stderr: Data()),
            AmpCommandResult(exitCode: 0, stdout: Data("updated 2.0.0\n".utf8), stderr: Data())
        ])
        let first = URL(fileURLWithPath: "/tmp/one/amp")
        let duplicate = URL(fileURLWithPath: "/tmp/one/../one/amp")
        let second = URL(fileURLWithPath: "/tmp/two/amp")
        let controller = AmpUpdateController(
            fetchRelease: { _ in Data("2.0.0".utf8) },
            executeCommand: { try await recorder.execute($0) }
        )
        controller.synchronizeExecutables([
            AmpExecutableRegistration(executableURL: first),
            AmpExecutableRegistration(executableURL: duplicate),
            AmpExecutableRegistration(executableURL: second)
        ])
        await controller.checkNow()
        await controller.installOutdatedExecutables()

        let requests = await recorder.requests
        XCTAssertEqual(requests.map { $0.executableURL.path }, [first.path, first.path, second.path, second.path])
        XCTAssertEqual(requests.map(\.arguments), [
            ["version"], ["update", "--porcelain"],
            ["version"], ["update", "--porcelain"]
        ])
        XCTAssertEqual(controller.lastCompletedInstallBatch?.results.map(\.path), [first.path, second.path])
    }
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
}

private enum TestError: Error { case message(String) }

private actor CommandRecorder {
    private(set) var requests: [AmpCommandRequest] = []
    private var results: [AmpCommandResult]
    init(results: [AmpCommandResult]) { self.results = results }
    func execute(_ request: AmpCommandRequest) throws -> AmpCommandResult {
        requests.append(request)
        return results.removeFirst()
    }
}

private actor GatedCommands {
    private var requests: [AmpCommandRequest] = []
    private let results: [String]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(results: [String]) { self.results = results }
    var requestCount: Int { requests.count }
    var recordedRequests: [AmpCommandRequest] { requests }

    func execute(_ request: AmpCommandRequest) async throws -> AmpCommandResult {
        let index = requests.count
        requests.append(request)
        await withCheckedContinuation { continuations[index] = $0 }
        return AmpCommandResult(exitCode: 0, stdout: Data(results[index].utf8), stderr: Data())
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }

    func resume(at index: Int) { continuations.removeValue(forKey: index)?.resume() }
}

private actor GatedFetches {
    private var requests: [URLRequest] = []
    private let values: [String]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(values: [String]) { self.values = values }
    var requestCount: Int { requests.count }

    func fetch(_ request: URLRequest) async throws -> Data {
        let index = requests.count
        requests.append(request)
        await withCheckedContinuation { continuations[index] = $0 }
        return Data(values[index].utf8)
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }

    func resume(at index: Int) { continuations.removeValue(forKey: index)?.resume() }
}

private actor SleepRecorder {
    private(set) var intervals: [TimeInterval] = []
    private(set) var cancellationCount = 0
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(_ interval: TimeInterval) async throws {
        intervals.append(interval)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuations.append($0) }
            } onCancel: {
                Task { await self.cancelPending() }
            }
        } catch {
            throw error
        }
    }

    func waitForCallCount(_ count: Int) async {
        while intervals.count < count { await Task.yield() }
    }

    func resumeNext() { continuations.removeFirst().resume() }

    func waitForCancellation() async {
        while cancellationCount == 0 { await Task.yield() }
    }

    private func cancelPending() {
        cancellationCount += 1
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

final class RunnerCoordinatorUpdateRegistrationTests: XCTestCase {
    @MainActor
    func testPathSaveInvalidatesOldProbeAndNextCentralProbeUsesResolvedPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = MemoryProfileIO()
        let store = RunnerProfileStore(fileURL: root.appendingPathComponent("profiles.json"), io: io)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pathStore = RunnerPathSettingsStore(defaults: defaults, key: "test")
        let commands = GatedCommands(results: ["1.0.0\n", "2.0.0\n"])
        let controller = AmpUpdateController(executeCommand: { try await commands.execute($0) })
        var profile = RunnerProfile(
            name: "One", runnerID: "one", workingDirectoryPath: root.path,
            ampExecutablePath: root.appendingPathComponent("bin/../amp").path
        )
        try store.save([profile])
        let coordinator = RunnerCoordinator(
            homeDirectoryPath: root.path, store: store, pathSettingsStore: pathStore,
            inheritedEnvironment: ["PATH": "/usr/bin"], ampUpdateController: controller
        )

        coordinator.onLaunch()
        XCTAssertEqual(controller.registeredExecutableURLs.map(\.path), [root.appendingPathComponent("amp").standardizedFileURL.path])

        profile.ampExecutablePath = root.appendingPathComponent("other-amp").path
        try coordinator.persist(profile)
        XCTAssertEqual(controller.registeredExecutableURLs.map(\.path), [profile.ampExecutablePath])

        let oldProbe = Task {
            await controller.installedVersion(
                for: URL(fileURLWithPath: profile.ampExecutablePath),
                environment: coordinator.runnerEnvironment()
            )
        }
        await commands.waitForRequestCount(1)
        try coordinator.savePathDirectories([root.path])
        XCTAssertEqual(controller.registeredExecutableURLs.map(\.path), [profile.ampExecutablePath])

        let refreshedProbe = Task {
            await controller.installedVersion(
                for: URL(fileURLWithPath: profile.ampExecutablePath),
                environment: coordinator.runnerEnvironment()
            )
        }
        await commands.waitForRequestCount(2)
        let requests = await commands.recordedRequests
        XCTAssertEqual(requests[1].environment["PATH"]?.split(separator: ":").first, Substring(root.path))
        await commands.resume(at: 1)
        let refreshedVersion = await refreshedProbe.value
        XCTAssertEqual(refreshedVersion, AmpVersion("2.0.0"))
        await commands.resume(at: 0)
        _ = await oldProbe.value
        XCTAssertEqual(controller.installedVersions[profile.ampExecutablePath], AmpVersion("2.0.0"))

        try coordinator.delete(profile)
        XCTAssertTrue(controller.registeredExecutableURLs.isEmpty)
    }
}

private final class MemoryProfileIO: ProfileStoreFileIO {
    private var data: Data?
    func read(from url: URL) throws -> Data? { data }
    func write(_ data: Data, to url: URL) throws { self.data = data }
}
