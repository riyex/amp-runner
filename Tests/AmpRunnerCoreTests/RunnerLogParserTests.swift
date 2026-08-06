import XCTest
@testable import AmpRunnerCore

final class RunnerLogParserTests: XCTestCase {

    private let parser = RunnerLogParser()

    // MARK: - Blank input

    func testBlankLinesProduceNoEvent() {
        XCTAssertNil(parser.parse(line: ""))
        XCTAssertNil(parser.parse(line: "    "))
        XCTAssertNil(parser.parse(line: "\n"))
    }

    // MARK: - Connection

    func testObservedRemoteControlPhraseMeansOnline() {
        XCTAssertEqual(
            parser.parse(line: "remote controlling the app runner"),
            .statusChanged(.online)
        )
    }

    func testRemoteControlPhraseIsMatchedCaseInsensitivelyWithinLongerLine() {
        XCTAssertEqual(
            parser.parse(line: "2026-07-28T10:00:00Z INFO Remote Controlling The App Runner (id=sample-runner)"),
            .statusChanged(.online)
        )
    }

    func testWaitingForThreadsMeansOnline() {
        XCTAssertEqual(
            parser.parse(line: "waiting for threads..."),
            .statusChanged(.online)
        )
    }

    func testRunnerReadyMeansOnline() {
        XCTAssertEqual(
            parser.parse(line: "runner is ready"),
            .statusChanged(.online)
        )
    }

    func testRegisteredMessageMeansOnline() {
        XCTAssertEqual(
            parser.parse(line: "16:51:46 Registered. Create threads on https://ampcode.com/ and they will run here. Have fun, happy hacking."),
            .statusChanged(.online)
        )
    }

    // MARK: - Thread lifecycle

    func testRunningThreadMeansThreadStarted() {
        XCTAssertEqual(
            parser.parse(line: "running thread T-12345"),
            .threadStarted(RunnerThreadDetails(
                id: "T-12345",
                webURLString: "https://ampcode.com/threads/T-12345"
            ))
        )
    }

    func testCurrentRunningThreadsSummaryDoesNotMeanLocalThreadStarted() {
        let threadID = "T-00000000-0000-7000-8000-000000000001"
        XCTAssertEqual(
            parser.parse(line: "16:51:42 Running (4 threads running) https://ampcode.com/threads/\(threadID)"),
            .unrecognizedLine("16:51:42 Running (4 threads running) https://ampcode.com/threads/\(threadID)")
        )
    }

    func testRemoteThreadRequestedMeansThreadStarted() {
        let threadID = "T-00000000-0000-7000-8000-000000000002"
        XCTAssertEqual(
            parser.parse(line: "18:49:59 Remote thread requested https://ampcode.com/threads/\(threadID)"),
            .threadStarted(RunnerThreadDetails(
                id: threadID,
                webURLString: "https://ampcode.com/threads/\(threadID)"
            ))
        )
    }

    func testSleptIdleThreadMeansOnlineWithoutNotification() {
        let threadID = "T-00000000-0000-7000-8000-000000000002"
        XCTAssertEqual(
            parser.parse(line: "18:54:25 Slept idle thread (0 threads running) https://ampcode.com/threads/\(threadID)"),
            .threadIdle(RunnerThreadDetails(
                id: threadID,
                webURLString: "https://ampcode.com/threads/\(threadID)"
            ))
        )
    }

    func testNewThreadMeansThreadStarted() {
        XCTAssertEqual(
            parser.parse(line: "Accepted new thread from ampcode.com"),
            .threadStarted(RunnerThreadDetails())
        )
    }

    func testThreadCompletedMeansThreadFinished() {
        XCTAssertEqual(
            parser.parse(line: "thread T-12345 completed"),
            .threadFinished(
                RunnerThreadDetails(
                    id: "T-12345",
                    webURLString: "https://ampcode.com/threads/T-12345"
                ),
                duration: nil
            )
        )
    }

    func testFinishedRunningThreadMeansThreadFinished() {
        XCTAssertEqual(
            parser.parse(line: "finished running thread T-1"),
            .threadFinished(
                RunnerThreadDetails(id: "T-1", webURLString: "https://ampcode.com/threads/T-1"),
                duration: nil
            )
        )
    }

    // MARK: - Failure

    func testThreadFailedCarriesTheOriginalLine() {
        let line = "thread failed: exit status 1"
        XCTAssertEqual(parser.parse(line: line), .threadFailed(line, thread: nil, duration: nil))
    }

    func testGenericErrorLineIsTreatedAsFailure() {
        let line = "ERROR connection refused"
        XCTAssertEqual(parser.parse(line: line), .threadFailed(line, thread: nil, duration: nil))
    }

    func testZeroErrorsIsNotAFailure() {
        // Exclusion list keeps benign summary lines from flipping the runner to Error.
        XCTAssertEqual(parser.parse(line: "thread completed with 0 errors"), .threadFinished(nil, duration: nil))
    }

    func testFailureMatchersWinOverCompletionMatchers() {
        let line = "thread failed after completed step 3"
        XCTAssertEqual(parser.parse(line: line), .threadFailed(line, thread: nil, duration: nil))
    }

    func testThreadDetailsMergesCliMetadataOverLogMetadata() {
        let logDetails = RunnerThreadDetails(
            id: "T-12345",
            webURLString: "https://ampcode.com/threads/T-12345"
        )
        let metadata = RunnerThreadDetails(
            id: "T-12345",
            title: "Core diff code review",
            treeURLString: "file:///Users/me/Developer/amp-runner",
            messageCount: 5
        )

        XCTAssertEqual(
            logDetails.merging(metadata),
            RunnerThreadDetails(
                id: "T-12345",
                title: "Core diff code review",
                webURLString: "https://ampcode.com/threads/T-12345",
                treeURLString: "file:///Users/me/Developer/amp-runner",
                messageCount: 5
            )
        )
    }

    // MARK: - Unrecognised

    func testUnknownLinesAreReportedVerbatimAndTrimmed() {
        XCTAssertEqual(
            parser.parse(line: "   some entirely unexpected output   "),
            .unrecognizedLine("some entirely unexpected output")
        )
    }

    func testUnrecognizedLineImpliesNoStatusChange() {
        XCTAssertNil(RunnerEvent.unrecognizedLine("noise").impliedStatus)
    }

    // MARK: - Implied status

    func testImpliedStatusMapping() {
        XCTAssertEqual(RunnerEvent.threadStarted(RunnerThreadDetails()).impliedStatus, .working)
        XCTAssertEqual(RunnerEvent.threadIdle(nil).impliedStatus, .online)
        XCTAssertEqual(RunnerEvent.threadFinished(nil, duration: nil).impliedStatus, .online)
        XCTAssertEqual(RunnerEvent.threadFailed("boom", thread: nil, duration: nil).impliedStatus, .error("boom"))
        XCTAssertEqual(RunnerEvent.statusChanged(.online).impliedStatus, .online)
    }

    func testNotifiableEvents() {
        XCTAssertTrue(RunnerEvent.threadStarted(RunnerThreadDetails()).isNotifiable)
        XCTAssertTrue(RunnerEvent.threadFinished(nil, duration: nil).isNotifiable)
        XCTAssertTrue(RunnerEvent.threadFailed("x", thread: nil, duration: nil).isNotifiable)
        XCTAssertFalse(RunnerEvent.threadIdle(nil).isNotifiable)
        XCTAssertFalse(RunnerEvent.statusChanged(.online).isNotifiable)
        XCTAssertFalse(RunnerEvent.unrecognizedLine("x").isNotifiable)
    }

    // MARK: - Extensibility

    func testCustomMatcherTableReplacesDefaults() {
        let custom = RunnerLogParser(matchers: [
            RunnerLogParser.Matcher(phrases: ["ready to rock"]) { _ in .statusChanged(.online) }
        ])
        XCTAssertEqual(custom.parse(line: "Ready to rock!"), .statusChanged(.online))
        // A default phrase is no longer recognised, proving the table is the only source.
        XCTAssertEqual(
            custom.parse(line: "waiting for threads"),
            .unrecognizedLine("waiting for threads")
        )
    }

    func testMatcherExclusionPreventsFiring() {
        let matcher = RunnerLogParser.Matcher(
            phrases: ["thread"],
            excludedPhrases: ["debug"]
        ) { _ in .threadStarted(RunnerThreadDetails()) }
        XCTAssertTrue(matcher.matches(lowercasedLine: "starting thread"))
        XCTAssertFalse(matcher.matches(lowercasedLine: "debug: starting thread"))
    }

    // MARK: - Status labels

    func testStatusDisplayNames() {
        XCTAssertEqual(RunnerStatus.stopped.displayName, "Stopped")
        XCTAssertEqual(RunnerStatus.starting.displayName, "Starting")
        XCTAssertEqual(RunnerStatus.online.displayName, "Online")
        XCTAssertEqual(RunnerStatus.working.displayName, "Working")
        XCTAssertEqual(RunnerStatus.error("nope").displayName, "Error")
    }

    func testErrorStatusDetailIncludesReason() {
        XCTAssertEqual(RunnerStatus.error("exit code 2").detailedDescription, "Error: exit code 2")
        XCTAssertEqual(RunnerStatus.error("").detailedDescription, "Error")
    }

    func testIsRunning() {
        XCTAssertTrue(RunnerStatus.starting.isRunning)
        XCTAssertTrue(RunnerStatus.online.isRunning)
        XCTAssertTrue(RunnerStatus.working.isRunning)
        XCTAssertFalse(RunnerStatus.stopped.isRunning)
        XCTAssertFalse(RunnerStatus.error("x").isRunning)
    }
}
