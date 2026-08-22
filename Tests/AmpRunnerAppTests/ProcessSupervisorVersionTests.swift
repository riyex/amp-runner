import XCTest
import AmpRunnerCore
@testable import AmpRunner

final class ProcessSupervisorVersionTests: XCTestCase {
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
        let supervisor = ProcessSupervisor(
            profile: fixture.profile,
            homeDirectoryPath: fixture.root.path,
            versionProvider: { _, _ in await counter.record() },
            monitorExecutableURL: fixture.monitorURL,
            restartPolicy: RunnerRestartPolicy(delays: [0, 0])
        )

        supervisor.start()
        try await waitUntil { supervisor.isRunning }
        supervisor.restart()
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

private struct SupervisorFixture {
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
    var count: Int { callbacks.count }

    func append(_ callback: @escaping @MainActor () -> Void) { callbacks.append(callback) }
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
