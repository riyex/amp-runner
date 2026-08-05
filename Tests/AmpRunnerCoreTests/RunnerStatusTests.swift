import XCTest
@testable import AmpRunnerCore

final class RunnerStatusTests: XCTestCase {

    func testMenuBarAggregateStatusUsesBrandPrecedence() {
        XCTAssertEqual(RunnerStatus.menuBarAggregateStatus(for: [.online, .error("exit 1"), .working]), .error)
        XCTAssertEqual(RunnerStatus.menuBarAggregateStatus(for: [.online, .working, .starting]), .working)
        XCTAssertEqual(RunnerStatus.menuBarAggregateStatus(for: [.online, .starting]), .starting)
        XCTAssertEqual(RunnerStatus.menuBarAggregateStatus(for: [.stopped, .online]), .online)
        XCTAssertEqual(RunnerStatus.menuBarAggregateStatus(for: [.stopped]), .stopped)
        XCTAssertEqual(RunnerStatus.menuBarAggregateStatus(for: []), .stopped)
    }
}
