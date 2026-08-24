import XCTest
@testable import AmpRunner

final class AppDelegateDuplicateInstanceTests: XCTestCase {
    @MainActor
    func testOlderInstanceWithSameBundleIdentifierMatchesAcrossBundleLocations() {
        let currentLaunchDate = Date()
        let candidate = AppDelegate.InstanceIdentity(
            bundleIdentifier: "com.riyex.amprunner",
            bundleURL: URL(fileURLWithPath: "/Applications/AmpRunner.app"),
            launchDate: currentLaunchDate.addingTimeInterval(-60),
            processID: 1_000,
            processStartTime: nil
        )
        let current = AppDelegate.InstanceIdentity(
            bundleIdentifier: "com.riyex.amprunner",
            bundleURL: URL(fileURLWithPath: "/tmp/Xcode/AmpRunner.app"),
            launchDate: currentLaunchDate,
            processID: 2_000,
            processStartTime: nil
        )

        XCTAssertTrue(AppDelegate.isOlderMatchingInstance(candidate, than: current))
    }

    @MainActor
    func testDifferentBundleIdentifierDoesNotMatch() {
        let currentLaunchDate = Date()
        let candidate = AppDelegate.InstanceIdentity(
            bundleIdentifier: "com.riyex.amprunner.dev",
            bundleURL: URL(fileURLWithPath: "/tmp/Xcode/AmpRunner.app"),
            launchDate: currentLaunchDate.addingTimeInterval(-60),
            processID: 1_000,
            processStartTime: nil
        )
        let current = AppDelegate.InstanceIdentity(
            bundleIdentifier: "com.riyex.amprunner",
            bundleURL: URL(fileURLWithPath: "/Applications/AmpRunner.app"),
            launchDate: currentLaunchDate,
            processID: 2_000,
            processStartTime: nil
        )

        XCTAssertFalse(AppDelegate.isOlderMatchingInstance(candidate, than: current))
    }

    @MainActor
    func testNewInstanceDetectsOlderInstanceAfterProcessIDWraparound() {
        let currentLaunchDate = Date()

        XCTAssertTrue(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: currentLaunchDate.addingTimeInterval(-60),
                candidateProcessID: 99_680,
                candidateProcessStartTime: nil,
                currentLaunchDate: currentLaunchDate,
                currentProcessID: 5_249,
                currentProcessStartTime: nil
            )
        )
    }

    @MainActor
    func testNewerInstanceIsNotTreatedAsOlder() {
        let currentLaunchDate = Date()

        XCTAssertFalse(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: currentLaunchDate.addingTimeInterval(60),
                candidateProcessID: 8_000,
                candidateProcessStartTime: nil,
                currentLaunchDate: currentLaunchDate,
                currentProcessID: 9_000,
                currentProcessStartTime: nil
            )
        )
    }

    @MainActor
    func testKernelStartTimeHandlesMissingLaunchDatesAndProcessIDWraparound() {
        XCTAssertTrue(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: nil,
                candidateProcessID: 99_680,
                candidateProcessStartTime: .init(seconds: 100, microseconds: 0),
                currentLaunchDate: nil,
                currentProcessID: 5_249,
                currentProcessStartTime: .init(seconds: 200, microseconds: 0)
            )
        )
    }

    @MainActor
    func testMissingChronologyUsesProcessIDAsDeterministicTieBreaker() {
        XCTAssertFalse(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: nil,
                candidateProcessID: 99_680,
                candidateProcessStartTime: nil,
                currentLaunchDate: nil,
                currentProcessID: 5_249,
                currentProcessStartTime: nil
            )
        )
        XCTAssertTrue(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: nil,
                candidateProcessID: 5_249,
                candidateProcessStartTime: nil,
                currentLaunchDate: nil,
                currentProcessID: 99_680,
                currentProcessStartTime: nil
            )
        )
    }

    @MainActor
    func testCurrentAndInvalidProcessesAreNotDuplicates() {
        XCTAssertFalse(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: Date(),
                candidateProcessID: 5_249,
                candidateProcessStartTime: nil,
                currentLaunchDate: Date(),
                currentProcessID: 5_249,
                currentProcessStartTime: nil
            )
        )
        XCTAssertFalse(
            AppDelegate.wasLaunchedBeforeCurrentProcess(
                candidateLaunchDate: Date(),
                candidateProcessID: 0,
                candidateProcessStartTime: nil,
                currentLaunchDate: Date(),
                currentProcessID: 5_249,
                currentProcessStartTime: nil
            )
        )
    }
}
