import XCTest
@testable import AmpRunnerCore

final class AmpRunnerBrandingTests: XCTestCase {

    func testNonAffiliationNoticeNamesSourcegraphAmpAndAmpCode() {
        let notice = AmpRunnerBranding.nonAffiliationNotice

        XCTAssertTrue(notice.contains("Sourcegraph"), notice)
        XCTAssertTrue(notice.contains("Amp"), notice)
        XCTAssertTrue(notice.contains("AmpCode"), notice)
        XCTAssertTrue(notice.contains("not affiliated"), notice)
    }
}
