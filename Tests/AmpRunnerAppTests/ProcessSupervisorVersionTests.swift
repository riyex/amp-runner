import XCTest
import Combine
import AmpRunnerCore
import Darwin
@testable import AmpRunner

final class ProcessSupervisorVersionTests: XCTestCase {
    @MainActor
    func testRejectedCompatibilityCheckNeverLaunchesRunner() async throws {
        let fixture = try SupervisorFixture()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in
                throw AmpRunnerCompatibility.Error.tooOld(AmpVersion("0.0.1")!)
            },
            monitorExecutableURL: fixture.monitorURL
        )
        supervisor.start()
        try await waitUntil { supervisor.status.errorMessage != nil }
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertTrue(supervisor.status.errorMessage?.contains("too old") == true)
        XCTAssertNil(supervisor.runningAmpVersion)
    }

    @MainActor
    func testStartProbesCapturedCommandAndEnvironmentThenPublishesVersionAfterLaunch() async throws {
        let fixture = try SupervisorFixture()
        var environmentCalls = 0
        var probedEnvironment: [String: String]?
        let expected = AmpVersion("1.2.3")
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            environmentProvider: {
                environmentCalls += 1
                return ["SNAPSHOT": "one"]
            },
            versionProvider: { command, environment in
                XCTAssertEqual(command.executableURL, fixture.ampURL)
                probedEnvironment = environment
                return expected
            },
            monitorExecutableURL: fixture.monitorURL
        )

        supervisor.start()
        try await waitUntil { supervisor.isRunning }

        XCTAssertEqual(environmentCalls, 1)
        XCTAssertEqual(probedEnvironment, ["SNAPSHOT": "one"])
        XCTAssertEqual(supervisor.runningAmpVersion, expected)
        supervisor.stop()
        try await waitUntil { supervisor.status == .stopped }
        XCTAssertNil(supervisor.runningAmpVersion)
    }

    @MainActor
    func testFailedProbeStillLaunchesWithoutVersion() async throws {
        let fixture = try SupervisorFixture()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in nil },
            monitorExecutableURL: fixture.monitorURL
        )

        supervisor.start()
        try await waitUntil { supervisor.isRunning }

        XCTAssertNil(supervisor.runningAmpVersion)
        supervisor.stop()
    }

    @MainActor
    func testStopDuringPendingProbeCancelsLaunch() async throws {
        let fixture = try SupervisorFixture()
        let gate = ProbeGate()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await gate.wait() },
            monitorExecutableURL: fixture.monitorURL
        )

        supervisor.start()
        await gate.waitUntilEntered()
        supervisor.stop()
        await gate.resume(with: AmpVersion("9.9.9"))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.status, .stopped)
        XCTAssertNil(supervisor.runningAmpVersion)
    }

    @MainActor
    func testRepeatedStartDuringProbeCreatesOneProbeAndLaunch() async throws {
        let fixture = try SupervisorFixture()
        let gate = ProbeGate()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await gate.wait() },
            monitorExecutableURL: fixture.monitorURL
        )

        supervisor.start()
        supervisor.start()
        await gate.waitUntilEntered()
        let callsWhilePending = await gate.callCount
        XCTAssertEqual(callsWhilePending, 1)
        await gate.resume(with: AmpVersion("2.0.0"))
        try await waitUntil { supervisor.isRunning }
        let callsAfterLaunch = await gate.callCount
        XCTAssertEqual(callsAfterLaunch, 1)
        supervisor.stop()
    }

    @MainActor
    func testRepeatedIntentionalRestartCreatesOneReplacementProbe() async throws {
        let fixture = try SupervisorFixture()
        let counter = ProbeCounter()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await counter.record() },
            monitorExecutableURL: fixture.monitorURL
        )

        supervisor.start()
        try await waitUntil { supervisor.isRunning }
        supervisor.restart()
        supervisor.restart()
        await counter.waitForCallCount(2)
        try await waitUntil(timeout: .seconds(4)) { supervisor.isRunning }

        let callCount = await counter.callCount
        XCTAssertEqual(callCount, 2)
        supervisor.stop()
    }

    @MainActor
    func testIntentionalRestartDoesNotConsumeAbnormalRetryBudget() async throws {
        let fixture = try SupervisorFixture()
        let counter = ProbeCounter()
        let callbacks = TerminationCallbackQueue()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await counter.record() },
            monitorExecutableURL: fixture.monitorURL,
            terminationCallbackScheduler: { callback in callbacks.appendFirstOtherwiseRun(callback) },
            restartPolicy: RunnerRestartPolicy(delays: [0, 0])
        )

        supervisor.start()
        try await waitUntil { supervisor.isRunning }
        supervisor.restart()
        try await waitUntil { callbacks.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        let callCountBeforeTerminationHandling = await counter.callCount
        XCTAssertEqual(callCountBeforeTerminationHandling, 1)
        callbacks.runFirst()
        await counter.waitForCallCount(2)
        try await waitUntil(timeout: .seconds(4)) { supervisor.isRunning }

        try "#!/bin/sh\nexit 7\n".write(to: fixture.ampURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.ampURL.path)
        supervisor.restart()
        try await waitUntil(timeout: .seconds(4)) {
            supervisor.status.errorMessage?.contains("restart limit reached after 2 attempts") == true
        }

        let callCount = await counter.callCount
        XCTAssertEqual(callCount, 5)
        XCTAssertNil(supervisor.runningAmpVersion)
    }

    @MainActor
    func testRestartDeadlineRelaunchesAfterDelayedTerminationHandlingCompletes() async throws {
        let fixture = try SupervisorFixture()
        let callbacks = TerminationCallbackQueue()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in AmpVersion("1.0.0") },
            monitorExecutableURL: fixture.monitorURL,
            terminationCallbackScheduler: { callback in callbacks.appendFirstOtherwiseRun(callback) },
            restartWaitTimeout: 0.1
        )

        supervisor.start()
        try await waitUntil { supervisor.isRunning }
        supervisor.restart()
        try await waitUntil { callbacks.count == 1 }
        try await waitUntil { supervisor.restartLifecycle == .failed }

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertTrue(supervisor.logLines.contains { $0.contains("restart timed out") })
        callbacks.runFirst()
        try await waitUntil { supervisor.isRunning }
        XCTAssertEqual(supervisor.restartLifecycle, .completed)
        supervisor.stop()
        try await waitUntil { supervisor.status == .stopped }
    }

    @MainActor
    func testStaleTerminationCannotClearReplacementLaunch() async throws {
        let fixture = try SupervisorFixture(ampScript: "#!/bin/sh\nexit 0\n")
        let callbacks = TerminationCallbackQueue()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in AmpVersion("3.0.0") },
            monitorExecutableURL: fixture.monitorURL,
            terminationCallbackScheduler: { callback in callbacks.append(callback) }
        )

        supervisor.start()
        try await waitUntil { callbacks.count == 1 }
        try "#!/bin/sh\nsleep 30\n".write(to: fixture.ampURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.ampURL.path)
        supervisor.start()
        try await waitUntil { supervisor.isRunning }
        callbacks.runFirst()

        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(supervisor.runningAmpVersion, AmpVersion("3.0.0"))
        supervisor.stop()
    }

    @MainActor
    func testAbnormalRetryUsesProviderWithoutResettingRetryPolicy() async throws {
        let fixture = try SupervisorFixture(ampScript: "#!/bin/sh\nexit 7\n")
        let counter = ProbeCounter()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await counter.record() },
            monitorExecutableURL: fixture.monitorURL,
            restartPolicy: RunnerRestartPolicy(delays: [0, 0])
        )

        supervisor.start()
        try await waitUntil { supervisor.status.errorMessage?.contains("restart limit reached after 2 attempts") == true }

        let callCount = await counter.callCount
        XCTAssertEqual(callCount, 3)
        XCTAssertNil(supervisor.runningAmpVersion)
    }

    @MainActor
    func testDuplicateRunnerOwnershipErrorDoesNotEmitThreadFailureOrRetry() async throws {
        let detail = "Error: Another Amp process is already serving remote threads for /tmp/project (pid 61439)"
        let fixture = try SupervisorFixture(
            ampScript: "#!/bin/sh\nwhile [ ! -f \"$0.go\" ]; do sleep 0.01; done\nsleep 5 &\nprintf '%s' '\(detail)' >&2\nexit 1\n"
        )
        let counter = ProbeCounter()
        let terminationCallback = TerminationCallbackBox()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await counter.record() },
            monitorExecutableURL: fixture.monitorURL,
            terminationCallbackScheduler: { terminationCallback.store($0) },
            restartPolicy: RunnerRestartPolicy(delays: [0])
        )
        var events: [RunnerEvent] = []
        let eventsSubscription = supervisor.events.sink { events.append($0) }
        defer { eventsSubscription.cancel() }

        supervisor.start()
        try await waitUntil { supervisor.isRunning }
        FileManager.default.createFile(atPath: fixture.ampURL.path + ".go", contents: Data())
        let callbackDeadline = Date().addingTimeInterval(2)
        while !terminationCallback.isPending && Date() < callbackDeadline {
            usleep(10_000)
        }
        XCTAssertTrue(terminationCallback.isPending)
        terminationCallback.run()
        try await waitUntil { !supervisor.isRunning && supervisor.status == .error(detail) }
        try await Task.sleep(for: .milliseconds(100))

        let callCount = await counter.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(events.contains { event in
            if case .threadFailed = event { return true }
            return false
        })
        XCTAssertFalse(supervisor.logLines.contains { $0.contains("restarting in") })
    }

    @MainActor
    func testPostProbeLaunchFailureNeverPublishesVersion() async throws {
        let fixture = try SupervisorFixture()
        try FileManager.default.removeItem(at: fixture.monitorURL)
        let gate = ProbeGate()
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await gate.wait() },
            monitorExecutableURL: fixture.monitorURL
        )

        supervisor.start()
        await gate.waitUntilEntered()
        XCTAssertEqual(supervisor.status, .starting)
        XCTAssertNil(supervisor.runningAmpVersion)

        await gate.resume(with: AmpVersion("8.0.0"))
        try await waitUntil { supervisor.status.errorMessage?.contains("Monitor helper is missing") == true }

        let probeCallCount = await gate.callCount
        XCTAssertEqual(probeCallCount, 1)
        XCTAssertNil(supervisor.runningAmpVersion)
        XCTAssertFalse(supervisor.isRunning)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private final class SupervisorFixture {
    let root: URL
    let ampURL: URL
    let monitorURL: URL
    let profile: RunnerProfile

    init(ampScript: String = "#!/bin/sh\nsleep 30\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ampURL = root.appendingPathComponent("amp")
        monitorURL = root.appendingPathComponent("monitor")
        try ampScript.write(to: ampURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"--\" ]; then shift; exec \"$@\"; fi\n  shift\ndone\n".write(to: monitorURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ampURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitorURL.path)
        profile = RunnerProfile(name: "Test", runnerID: "test", workingDirectoryPath: root.path, ampExecutablePath: ampURL.path, arguments: [])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TerminationCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@MainActor () -> Void)?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func store(_ callback: @escaping @MainActor () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    @MainActor
    func run() {
        lock.lock()
        let callback = callback
        self.callback = nil
        lock.unlock()
        callback?()
    }
}

private actor ProbeCounter {
    private(set) var callCount = 0

    func record() -> AmpVersion? {
        callCount += 1
        return AmpVersion("1.0.0")
    }

    func waitForCallCount(_ expected: Int) async {
        while callCount < expected { await Task.yield() }
    }
}

@MainActor
private final class TerminationCallbackQueue {
    private var callbacks: [@MainActor () -> Void] = []
    private var hasQueuedFirstCallback = false
    var count: Int { callbacks.count }

    func append(_ callback: @escaping @MainActor () -> Void) { callbacks.append(callback) }
    func appendFirstOtherwiseRun(_ callback: @escaping @MainActor () -> Void) {
        if hasQueuedFirstCallback {
            callback()
        } else {
            hasQueuedFirstCallback = true
            callbacks.append(callback)
        }
    }
    func runFirst() { callbacks.removeFirst()() }
}

private extension RunnerStatus {
    var errorMessage: String? {
        guard case .error(let message) = self else { return nil }
        return message
    }
}

private actor ProbeGate {
    private var continuation: CheckedContinuation<AmpVersion?, Never>?
    private(set) var callCount = 0

    func wait() async -> AmpVersion? {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while continuation == nil { await Task.yield() }
    }

    func resume(with version: AmpVersion?) {
        continuation?.resume(returning: version)
        continuation = nil
    }
}
