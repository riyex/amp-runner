import XCTest
@testable import AmpRunnerCore

final class RunnerRestartPolicyTests: XCTestCase {

    func testAbnormalExitsUseConfiguredDelays() {
        var policy = RunnerRestartPolicy(delays: [2, 5, 15], failureWindow: 60)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.recordAbnormalExit(at: now), .restart(after: 2, attempt: 1))
        XCTAssertEqual(policy.recordAbnormalExit(at: now.addingTimeInterval(10)), .restart(after: 5, attempt: 2))
        XCTAssertEqual(policy.recordAbnormalExit(at: now.addingTimeInterval(20)), .restart(after: 15, attempt: 3))
    }

    func testPolicyStopsAfterDelayBudgetIsExhaustedInsideFailureWindow() {
        var policy = RunnerRestartPolicy(delays: [2, 5, 15], failureWindow: 60)
        let now = Date(timeIntervalSince1970: 2_000)

        _ = policy.recordAbnormalExit(at: now)
        _ = policy.recordAbnormalExit(at: now.addingTimeInterval(10))
        _ = policy.recordAbnormalExit(at: now.addingTimeInterval(20))

        let decision = policy.recordAbnormalExit(at: now.addingTimeInterval(30))

        guard case .stop(let message) = decision else {
            return XCTFail("Expected stop after exhausting restart delays, got \(decision)")
        }
        XCTAssertTrue(message.contains("restart limit reached after 3 attempts"))
    }

    func testPolicyPrunesFailuresOutsideFailureWindow() {
        var policy = RunnerRestartPolicy(delays: [2, 5, 15], failureWindow: 60)
        let now = Date(timeIntervalSince1970: 3_000)

        _ = policy.recordAbnormalExit(at: now)
        _ = policy.recordAbnormalExit(at: now.addingTimeInterval(10))

        XCTAssertEqual(
            policy.recordAbnormalExit(at: now.addingTimeInterval(71)),
            .restart(after: 2, attempt: 1)
        )
    }

    func testResetClearsRecordedFailures() {
        var policy = RunnerRestartPolicy(delays: [2, 5, 15], failureWindow: 60)
        let now = Date(timeIntervalSince1970: 4_000)

        _ = policy.recordAbnormalExit(at: now)
        policy.reset()

        XCTAssertEqual(policy.recordAbnormalExit(at: now.addingTimeInterval(10)), .restart(after: 2, attempt: 1))
    }
}
