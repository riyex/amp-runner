import Foundation
import XCTest
@testable import AmpRunner

final class AmpCommandExecutorTests: XCTestCase {
    func testExecutesURLDirectlyWithSeparateArgumentsAndEnvironment() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        printf '%s\\n' "$1" "$2" "$FIXTURE_VALUE"
        """)

        let result = try await execute(
            executable,
            arguments: ["one argument", "$(printf shell-interpreted)"],
            environment: ["FIXTURE_VALUE": "from environment"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "one argument\n$(printf shell-interpreted)\nfrom environment\n")
        XCTAssertEqual(result.stderr, Data())
    }

    func testCapturesStdoutAndStderrIndependentlyAndReturnsNonzeroStatus() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        printf stdout-value
        printf stderr-value >&2
        exit 23
        """)

        let result = try await execute(executable)

        XCTAssertEqual(result.exitCode, 23)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "stdout-value")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "stderr-value")
    }

    func testTerminatesProcessAtTimeout() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        while :; do :; done
        """)
        let request = AmpCommandRequest(
            executableURL: executable,
            arguments: [],
            environment: [:],
            timeout: 0.1,
            outputLimit: 1_024
        )

        let start = Date()
        do {
            _ = try await AmpCommandExecutor().execute(request)
            XCTFail("Expected timeout")
        } catch AmpCommandExecutor.Error.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testCancellationReturnsPromptly() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        trap '' TERM
        while :; do :; done
        """)
        let task = Task {
            try await execute(executable, timeout: 30)
        }

        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testEscalatesToKillWhenProcessIgnoresTermination() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        trap '' TERM
        while :; do :; done
        """)

        let start = Date()
        do {
            _ = try await execute(executable, timeout: 0.1)
            XCTFail("Expected timeout")
        } catch AmpCommandExecutor.Error.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testTimeoutReturnsWhenDescendantInheritsOutputPipes() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        sleep 30 &
        while :; do :; done
        """)

        let start = Date()
        do {
            _ = try await execute(executable, timeout: 0.1)
            XCTFail("Expected timeout")
        } catch AmpCommandExecutor.Error.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testSuccessfulProcessReturnsWhenDescendantKeepsOutputPipesOpen() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        sleep 30 &
        printf complete
        exit 0
        """)

        let start = Date()
        let result = try await execute(executable, timeout: 2)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "complete")
    }

    func testRetainsBoundedOutputWhileDrainingBothStreams() async throws {
        let executable = try makeFixture("""
        #!/bin/sh
        i=0
        while [ "$i" -lt 262144 ]; do
          printf o
          printf e >&2
          i=$((i + 1))
        done
        """)

        let result = try await execute(executable, timeout: 10, outputLimit: 37)

        XCTAssertEqual(result.exitCode, 0)
        // outputLimit is a per-stream retained-byte cap; both pipes continue draining.
        XCTAssertEqual(result.stdout, Data(repeating: Character("o").asciiValue!, count: 37))
        XCTAssertEqual(result.stderr, Data(repeating: Character("e").asciiValue!, count: 37))
    }

    private func execute(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval = 2,
        outputLimit: Int = 1_024
    ) async throws -> AmpCommandResult {
        try await AmpCommandExecutor().execute(
            AmpCommandRequest(
                executableURL: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                outputLimit: outputLimit
            )
        )
    }

    private func makeFixture(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fixture.sh")
        try Data(contents.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
