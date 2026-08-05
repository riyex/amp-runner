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
}
