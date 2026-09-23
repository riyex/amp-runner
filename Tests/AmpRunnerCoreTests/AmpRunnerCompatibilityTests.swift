import XCTest
@testable import AmpRunnerCore

final class AmpRunnerCompatibilityTests: XCTestCase {
    func testRejectsOlderReleaseAndAcceptsMinimumAndNewer() throws {
        XCTAssertThrowsError(try AmpRunnerCompatibility.validate("0.0.1790103931-gffff (released yesterday)"))
        XCTAssertEqual(try AmpRunnerCompatibility.validate("0.0.1790103932-g7c3282 (released today)\n").description,
                       "0.0.1790103932-g7c3282")
        XCTAssertEqual(try AmpRunnerCompatibility.validate("0.0.1790103933-gaaaaa").description,
                       "0.0.1790103933-gaaaaa")
    }

    func testUnknownVersionCannotBypassMinimum() {
        for output in ["", "amp version unknown", "unexpected diagnostic", "0.0.not-a-build"] {
            XCTAssertThrowsError(try AmpRunnerCompatibility.validate(output))
        }
    }
}
