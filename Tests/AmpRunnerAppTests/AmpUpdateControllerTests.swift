import XCTest
import AmpRunnerCore
@testable import AmpRunner

final class AmpUpdateControllerTests: XCTestCase {
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
    func testIdentityChangeAndNewReleaseEachPermitAReprobe() async {
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
        XCTAssertEqual(observed, AmpVersion("1.3.0"))
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 3)
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
        await controller.installOutdatedExecutables(automatic: true)
        XCTAssertEqual(controller.installedVersions[url.standardizedFileURL.path], AmpVersion("1.0.0"))
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 2)
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
