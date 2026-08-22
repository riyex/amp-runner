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

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ampURL = root.appendingPathComponent("amp")
        monitorURL = root.appendingPathComponent("monitor")
        try "#!/bin/sh\nsleep 30\n".write(to: ampURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"--\" ]; then shift; exec \"$@\"; fi\n  shift\ndone\n".write(to: monitorURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ampURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitorURL.path)
        profile = RunnerProfile(name: "Test", runnerID: "test", workingDirectoryPath: root.path, ampExecutablePath: ampURL.path, arguments: [])
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
