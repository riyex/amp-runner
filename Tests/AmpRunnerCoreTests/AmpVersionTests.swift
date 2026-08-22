import Foundation
import XCTest
@testable import AmpRunnerCore

final class AmpVersionTests: XCTestCase {
    func testParsesReleaseResponse() throws {
        XCTAssertEqual(
            try AmpReleaseResponse.parse(Data("0.0.1787342526-gc11bfb\n".utf8)),
            AmpVersion("0.0.1787342526-gc11bfb")
        )
    }

    func testParsesVersionCommandFirstToken() throws {
        XCTAssertEqual(
            try AmpVersionCommandOutput.parse(
                "0.0.1787227443-g56d703 (released 2026-08-20T12:04:03.000Z, 1d ago)\n"
            ),
            AmpVersion("0.0.1787227443-g56d703")
        )
    }

    func testRejectsInvalidExternalVersionFormats() {
        XCTAssertThrowsError(try AmpReleaseResponse.parse(Data()))
        XCTAssertThrowsError(try AmpReleaseResponse.parse(Data([0xFF])))
        XCTAssertThrowsError(try AmpReleaseResponse.parse(Data("1.2.3 bad\n".utf8)))
        XCTAssertThrowsError(try AmpVersionCommandOutput.parse(""))
        XCTAssertThrowsError(try AmpVersionCommandOutput.parse("version 1.2.3"))
    }

    func testFailableInitializerRejectsMalformedVersions() {
        XCTAssertNil(AmpVersion("1"))
        XCTAssertNil(AmpVersion("1.x.3"))
        XCTAssertNil(AmpVersion("1.2.3-"))
        XCTAssertNil(AmpVersion("version1.2.3"))
        XCTAssertNil(AmpVersion("1.2.3 beta"))
    }

    func testComparesNormalizedVersions() {
        XCTAssertLessThan(AmpVersion("0.0.9")!, AmpVersion("0.0.10")!)
        XCTAssertEqual(AmpVersion("1.2")!, AmpVersion("1.2.0")!)
        XCTAssertLessThan(AmpVersion("1.2.3-ga")!, AmpVersion("1.2.3-gb")!)
        XCTAssertLessThan(AmpVersion("1.2.3-ga")!, AmpVersion("1.2.3")!)
    }

    func testHashingUsesNormalizedComponentsAndOriginalStringIsRetained() {
        XCTAssertEqual(Set([AmpVersion("1.2")!, AmpVersion("1.2.0")!]).count, 1)
        XCTAssertEqual(AmpVersion("1.2.0-ga")?.description, "1.2.0-ga")
    }
}
