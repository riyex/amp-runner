import XCTest
@testable import AmpRunnerCore

final class AmpUpdateOutputTests: XCTestCase {
    func testParsesUpdatedOutput() throws {
        XCTAssertEqual(
            try AmpUpdateOutput.parse("updated 0.0.1787342526-gc11bfb\n"),
            .updated(AmpVersion("0.0.1787342526-gc11bfb")!)
        )
    }

    func testParsesNoUpdateNeededOutput() throws {
        XCTAssertEqual(try AmpUpdateOutput.parse("no update needed\n"), .noUpdateNeeded)
    }

    func testRejectsNonPorcelainOutput() {
        let invalidOutputs = [
            "Updated 1.2.3", "updated", "updated 1.2.3 now",
            "updated 1.2.3\nno update needed", "Amp is already up to date."
        ]
        for output in invalidOutputs {
            XCTAssertThrowsError(try AmpUpdateOutput.parse(output), output)
        }
    }
}
