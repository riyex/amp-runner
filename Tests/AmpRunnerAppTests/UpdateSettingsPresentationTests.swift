import XCTest
import AmpRunnerCore
@testable import AmpRunner

final class UpdateSettingsPresentationTests: XCTestCase {
    func testExecutablePresentationShowsInstallFailureAlongsideKnownVersion() {
        let presentation = AmpExecutableRowPresentation(
            version: AmpVersion("1.2.3"),
            probeError: nil,
            installState: .failed("Directory is not writable")
        )

        XCTAssertEqual(presentation.versionText, "Amp 1.2.3")
        XCTAssertEqual(presentation.errorText, "Directory is not writable")
    }

    func testExecutablePresentationUsesProbeErrorWhenVersionIsUnknown() {
        let presentation = AmpExecutableRowPresentation(
            version: nil,
            probeError: "Version probe failed",
            installState: nil
        )

        XCTAssertEqual(presentation.versionText, "Amp version unknown")
        XCTAssertEqual(presentation.errorText, "Version probe failed")
    }
}
