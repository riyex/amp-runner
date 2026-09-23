import XCTest
import AppKit
import AmpRunnerCore
@testable import AmpRunner

final class AmpCompatibilityTests: XCTestCase {
    @MainActor
    func testUpgradePromptProvidesInstructionsWithoutAnInstallAction() throws {
        let message = "/Users/developer/.amp/bin/amp\n" + AmpRunnerCompatibility.Error.tooOld(AmpVersion("0.0.1790000000-g123456")!).localizedDescription
        let alert = RunnerCoordinator.compatibilityAlert(message: message)
        alert.layout()
        XCTAssertEqual(alert.buttons.map { $0.accessibilityTitle() }, ["Upgrade Instructions", "Not Now"])
        XCTAssertTrue(alert.informativeText.contains(message))
        XCTAssertTrue(alert.buttons.allSatisfy { $0.isEnabled })
        let view = try XCTUnwrap(alert.window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Amp compatibility warning"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testStartupChecksEachExecutableAndBlocksOnlyIncompatibleProfiles() async throws {
        let root = try temporaryDirectory()
        let old = try executable(in: root, name: "old", version: "0.0.1")
        let modern = try executable(in: root, name: "modern", version: "0.0.1790103932-g7c3282")
        var warnings: [String] = []
        let coordinator = RunnerCoordinator(homeDirectoryPath: root.path,
            compatibilityWarningPresenter: { warnings.append($0) })
        let first = try profile(in: root, name: "first", executable: old)
        let second = try profile(in: root, name: "second", executable: old)
        let third = try profile(in: root, name: "third", executable: modern)
        for profile in [first, second, third] { try coordinator.persist(profile) }

        let blocked = await coordinator.checkStartupCompatibility()
        XCTAssertEqual(blocked, [first.id, second.id])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains(old.path))
        XCTAssertFalse(warnings[0].contains(modern.path))
        XCTAssertEqual(try String(contentsOfFile: old.path + ".probes"), "x")
        XCTAssertEqual(try String(contentsOfFile: modern.path + ".probes"), "x")

        // Startup must not launch the older auto-start profiles, but the supported
        // profile is allowed through without any upgrade action.
        coordinator.onLaunch()
        defer { coordinator.onTerminate() }
        try await waitUntil { coordinator.supervisors[third.id]?.isRunning == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path + ".launched"))
        XCTAssertEqual(warnings.count, 2)
        coordinator.stopAll()
    }

    @MainActor
    func testManualUpgradeIsRecheckedBeforeNextStart() async throws {
        let root = try temporaryDirectory()
        let amp = try executable(in: root, name: "amp", version: "unknown")
        var warnings: [String] = []
        let coordinator = RunnerCoordinator(homeDirectoryPath: root.path,
            compatibilityWarningPresenter: { warnings.append($0) })
        let profile = try profile(in: root, name: "runner", executable: amp)
        try coordinator.persist(profile)
        coordinator.requestStart(profile)
        defer { coordinator.onTerminate() }
        try await waitUntil {
            if case .error = coordinator.status(for: profile) { return true }
            return false
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: amp.path + ".launched"))
        try "0.0.1790103933-gaaaaa".write(toFile: amp.path + ".version", atomically: true, encoding: .utf8)
        coordinator.requestStart(profile)
        try await waitUntil { coordinator.supervisors[profile.id]?.isRunning == true }
        XCTAssertEqual(coordinator.supervisors[profile.id]?.runningAmpVersion?.description, "0.0.1790103933-gaaaaa")
        XCTAssertEqual(warnings.count, 1)
        coordinator.stopAll()
    }

    func testNonzeroVersionCommandCannotPassWithValidLookingOutput() async throws {
        let root = try temporaryDirectory()
        let amp = try executable(in: root, name: "broken", version: "unused")
        try "#!/bin/sh\nprintf '0.0.1790103932-g7c3282'\nexit 23\n".write(to: amp, atomically: false, encoding: .utf8)
        let command = ResolvedRunnerCommand(executableURL: amp, arguments: [], workingDirectoryURL: root)
        do {
            _ = try await AmpCompatibilityChecker.check(command: command, environment: [:])
            XCTFail("A failed version command must block startup")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("status 23"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func executable(in root: URL, name: String, version: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try """
        #!/bin/sh
        if [ "$1" = --version ]; then
          printf x >> "$0.probes"
          /bin/cat "$0.version"
          exit 0
        fi
        printf launched > "$0.launched"
        exec /bin/sleep 30
        """.write(to: url, atomically: true, encoding: .utf8)
        try version.write(toFile: url.path + ".version", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func profile(in root: URL, name: String, executable: URL) throws -> RunnerProfile {
        let directory = root.appendingPathComponent(name + "-cwd")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RunnerProfile(name: name, runnerID: name, workingDirectoryPath: directory.path,
                             ampExecutablePath: executable.path, autoStart: true, confirmBeforeStart: false)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
