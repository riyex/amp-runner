import XCTest
@testable import AmpRunnerCore

final class AmpExecutableDetectorTests: XCTestCase {

    private let home = "/Users/tester"

    func testPrefersDefaultInstallerBinaryBeforePathWrappers() {
        let found = AmpExecutableDetector.detect(
            environmentPath: "/Users/tester/.local/bin:/Users/tester/bin",
            homeDirectoryPath: home
        ) { path in
            path == "/Users/tester/.local/bin/amp" || path == "/Users/tester/.amp/bin/amp"
        }

        XCTAssertEqual(found, "/Users/tester/.amp/bin/amp")
    }

    func testDetectsExecutableFromCustomAmpHomeBeforeDefaultHome() {
        let found = AmpExecutableDetector.detect(
            environmentPath: nil,
            ampHomePath: "/Volumes/Tools/amp",
            homeDirectoryPath: home
        ) { path in
            path == "/Volumes/Tools/amp/bin/amp" || path == "/Users/tester/.amp/bin/amp"
        }

        XCTAssertEqual(found, "/Volumes/Tools/amp/bin/amp")
    }

    func testDetectsExecutableFromEnvironmentPath() {
        let found = AmpExecutableDetector.detect(
            environmentPath: "/not-there:/Users/tester/bin",
            homeDirectoryPath: home
        ) { path in
            path == "/Users/tester/bin/amp"
        }

        XCTAssertEqual(found, "/Users/tester/bin/amp")
    }

    func testDetectsUserLocalFallbackWithExpandedHomeDirectory() {
        let found = AmpExecutableDetector.detect(
            environmentPath: nil,
            homeDirectoryPath: home
        ) { path in
            path == "/Users/tester/.local/bin/amp"
        }

        XCTAssertEqual(found, "/Users/tester/.local/bin/amp")
    }

    func testIgnoresRelativeEnvironmentPathEntries() {
        let found = AmpExecutableDetector.detect(
            environmentPath: "relative/bin:/Users/tester/bin",
            homeDirectoryPath: home
        ) { path in
            path == "relative/bin/amp" || path == "/Users/tester/bin/amp"
        }

        XCTAssertEqual(found, "/Users/tester/bin/amp")
    }

    func testCanonicalUpdateExecutableResolvesAmpPathWrapper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ampHome = root.appendingPathComponent(".amp", isDirectory: true)
        let directExecutable = ampHome.appendingPathComponent("bin/amp")
        let wrapper = root.appendingPathComponent(".local/bin/amp")
        try FileManager.default.createDirectory(
            at: directExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: directExecutable)
        try Data(
            """
            #!/usr/bin/env bash
            # Amp CLI PATH wrapper - simply execs the main script
            exec "${AMP_HOME:-$HOME/.amp}/bin/amp" "$@"
            """.utf8
        ).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directExecutable.path
        )

        let resolved = AmpExecutableResolver.resolveUpdateExecutable(
            configuredURL: wrapper,
            environment: ["HOME": root.path]
        )

        XCTAssertEqual(resolved.path, directExecutable.path)
    }

    func testCanonicalUpdateExecutableResolvesSymbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directExecutable = root.appendingPathComponent(".amp/bin/amp")
        let symlink = root.appendingPathComponent(".local/bin/amp")
        try FileManager.default.createDirectory(
            at: directExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: symlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: directExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directExecutable.path
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: directExecutable)

        let resolved = AmpExecutableResolver.resolveUpdateExecutable(
            configuredURL: symlink,
            environment: [:]
        )

        XCTAssertEqual(resolved.path, directExecutable.path)
    }

    func testCanonicalUpdateExecutableLeavesUnknownScriptsIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("amp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho custom\n".utf8).write(to: script)

        let resolved = AmpExecutableResolver.resolveUpdateExecutable(
            configuredURL: script,
            environment: [:]
        )

        XCTAssertEqual(resolved.path, script.path)
    }

    func testCanonicalUpdateExecutableDoesNotRedirectRelativeAmpHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appendingPathComponent("work")
        let directExecutable = workingDirectory.appendingPathComponent("tools/bin/amp")
        let wrapper = root.appendingPathComponent("amp")
        try FileManager.default.createDirectory(
            at: directExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: directExecutable)
        try Data(#"exec "${AMP_HOME:-$HOME/.amp}/bin/amp" "$@""#.utf8).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directExecutable.path
        )

        let resolved = AmpExecutableResolver.resolveUpdateExecutable(
            configuredURL: wrapper,
            environment: ["AMP_HOME": "tools"]
        )

        XCTAssertEqual(resolved.path, wrapper.path)
    }

    func testCanonicalUpdateExecutableDoesNotExpandTildeFromAmpHomeValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directExecutable = root.appendingPathComponent(".custom/bin/amp")
        let wrapper = root.appendingPathComponent("amp")
        try FileManager.default.createDirectory(
            at: directExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: directExecutable)
        try Data(#"exec "${AMP_HOME:-$HOME/.amp}/bin/amp" "$@""#.utf8).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directExecutable.path
        )

        let resolved = AmpExecutableResolver.resolveUpdateExecutable(
            configuredURL: wrapper,
            environment: ["AMP_HOME": "~/.custom", "HOME": root.path]
        )

        XCTAssertEqual(resolved.path, wrapper.path)
    }

    func testCanonicalUpdateExecutableKeepsWrapperWhenTargetIsNotExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directExecutable = root.appendingPathComponent(".amp/bin/amp")
        let wrapper = root.appendingPathComponent("amp")
        try FileManager.default.createDirectory(
            at: directExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: directExecutable)
        try Data(#"exec "${AMP_HOME:-$HOME/.amp}/bin/amp" "$@""#.utf8).write(to: wrapper)

        let resolved = AmpExecutableResolver.resolveUpdateExecutable(
            configuredURL: wrapper,
            environment: ["HOME": root.path]
        )

        XCTAssertEqual(resolved.path, wrapper.path)
    }
}
