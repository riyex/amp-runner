import XCTest
@testable import AmpRunnerCore
@testable import AmpRunnerMonitorSupport

final class RunnerProcessLauncherTests: XCTestCase {

    func testLaunchPlanUsesNativeMonitorExecutable() {
        let command = ResolvedRunnerCommand(
            executableURL: URL(fileURLWithPath: "/Users/tester/.amp/bin/amp"),
            arguments: ["--no-tui", "--runner-id", "sample-runner"],
            workingDirectoryURL: URL(fileURLWithPath: "/Users/tester/project")
        )
        let monitorURL = URL(fileURLWithPath: "/Applications/AmpRunner.app/Contents/Helpers/AmpRunnerMonitor")

        let plan = RunnerProcessLauncher.monitoredLaunchPlan(
            for: command,
            monitorExecutableURL: monitorURL,
            parentProcessID: 1234,
            pollIntervalSeconds: 0.5,
            shutdownTimeoutSeconds: 8
        )

        XCTAssertEqual(plan.executableURL, monitorURL)
        XCTAssertEqual(
            plan.arguments,
            [
                "--parent-pid", "1234",
                "--poll-interval", "0.5",
                "--shutdown-timeout", "8.0",
                "--",
                "/Users/tester/.amp/bin/amp",
                "--no-tui",
                "--runner-id",
                "sample-runner"
            ]
        )
    }

    func testNativeMonitorRunsCommandAndPreservesExitStatus() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = RunnerProcessMonitorConfiguration(
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            pollInterval: 0.05,
            shutdownTimeout: 0.2,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'child output'; exit 7"],
            workingDirectoryURL: root
        )

        let output = Pipe()
        let status = RunnerProcessMonitor(configuration: configuration).run(
            standardOutput: output.fileHandleForWriting,
            standardError: FileHandle.nullDevice
        )
        try output.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "child output")
        XCTAssertEqual(status, 7)
    }

    func testNativeMonitorChildInheritsMonitorEnvironment() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let variableName = "AMP_RUNNER_PATH_TEST"
        let value = "monitor-environment-\(UUID().uuidString)"
        let previousValue = getenv(variableName).map { String(cString: $0) }
        setenv(variableName, value, 1)
        defer {
            if let previousValue {
                setenv(variableName, previousValue, 1)
            } else {
                unsetenv(variableName)
            }
        }

        let configuration = RunnerProcessMonitorConfiguration(
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            pollInterval: 0.05,
            shutdownTimeout: 0.2,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$AMP_RUNNER_PATH_TEST\""],
            workingDirectoryURL: root
        )

        let output = Pipe()
        let status = RunnerProcessMonitor(configuration: configuration).run(
            standardOutput: output.fileHandleForWriting,
            standardError: FileHandle.nullDevice
        )
        try output.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), value)
        XCTAssertEqual(status, 0)
    }

    func testNativeMonitorTerminatesChildWhenWatchedParentExits() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let markerURL = root.appendingPathComponent("marker.txt")
        let childURL = try makeLongRunningChildScript(in: root)

        let watchedParent = Process()
        watchedParent.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchedParent.arguments = ["-c", "sleep 0.2"]
        try watchedParent.run()

        let configuration = RunnerProcessMonitorConfiguration(
            parentProcessID: watchedParent.processIdentifier,
            pollInterval: 0.05,
            shutdownTimeout: 0.2,
            executableURL: childURL,
            arguments: [markerURL.path],
            workingDirectoryURL: root
        )

        let status = RunnerProcessMonitor(configuration: configuration).run(
            standardOutput: FileHandle.nullDevice,
            standardError: FileHandle.nullDevice
        )
        XCTAssertTrue(waitForFile(markerURL, toContain: "started", timeout: 2))

        watchedParent.waitUntilExit()

        XCTAssertEqual(status, 0)
        XCTAssertTrue(try markerText(at: markerURL).contains("terminated"))
    }

    func testNativeMonitorExitsCleanlyWhenStopRequested() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let markerURL = root.appendingPathComponent("marker.txt")
        let childURL = try makeLongRunningChildScript(in: root)

        let configuration = RunnerProcessMonitorConfiguration(
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            pollInterval: 0.05,
            shutdownTimeout: 0.2,
            executableURL: childURL,
            arguments: [markerURL.path],
            workingDirectoryURL: root
        )
        let monitor = RunnerProcessMonitor(configuration: configuration)
        let result = AsyncResult<Int32>()

        Thread {
            let status = monitor.run(
                standardOutput: FileHandle.nullDevice,
                standardError: FileHandle.nullDevice
            )
            result.complete(status)
        }.start()

        XCTAssertTrue(waitForFile(markerURL, toContain: "started", timeout: 2))
        monitor.requestStop()
        XCTAssertEqual(result.value(timeout: 3), 0)
        XCTAssertTrue(try markerText(at: markerURL).contains("terminated"))
    }

    func testNativeMonitorConfigurationParsesCommandLineArguments() throws {
        let configuration = try RunnerProcessMonitorConfiguration.parse(
            arguments: [
                "--parent-pid", "1234",
                "--poll-interval", "0.5",
                "--shutdown-timeout", "8",
                "--",
                "/Users/tester/.amp/bin/amp",
                "--no-tui",
                "--runner-id",
                "sample-runner"
            ],
            workingDirectoryURL: URL(fileURLWithPath: "/Users/tester/project")
        )

        XCTAssertEqual(configuration.parentProcessID, 1234)
        XCTAssertEqual(configuration.pollInterval, 0.5)
        XCTAssertEqual(configuration.shutdownTimeout, 8)
        XCTAssertEqual(configuration.executableURL.path, "/Users/tester/.amp/bin/amp")
        XCTAssertEqual(configuration.arguments, ["--no-tui", "--runner-id", "sample-runner"])
        XCTAssertEqual(configuration.workingDirectoryURL.path, "/Users/tester/project")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("amp-runner-process-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeLongRunningChildScript(in root: URL) throws -> URL {
        let scriptURL = root.appendingPathComponent("child.sh")
        let script = """
        #!/bin/sh
        marker="$1"
        echo started > "$marker"
        trap 'echo terminated >> "$marker"; exit 0' INT TERM HUP
        while :; do
            sleep 1
        done
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func waitForFile(_ url: URL, toContain expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? markerText(at: url), text.contains(expected) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func markerText(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

private final class AsyncResult<Value> {
    private let condition = NSCondition()
    private var storedValue: Value?

    func complete(_ value: Value) {
        condition.lock()
        storedValue = value
        condition.broadcast()
        condition.unlock()
    }

    func value(timeout: TimeInterval) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while storedValue == nil && Date() < deadline {
            condition.wait(until: deadline)
        }
        return storedValue
    }
}
