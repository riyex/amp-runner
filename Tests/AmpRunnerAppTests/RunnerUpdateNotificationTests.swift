import XCTest
import AmpRunnerCore
@testable import AmpRunner

final class RunnerUpdateNotificationTests: XCTestCase {
    func testPureBuilderCreatesSeparateAggregateUpdateContent() {
        let update = RunnerUpdateNotificationBuilder.build(.updateAvailable(
            version: AmpVersion("2.0.0")!, executableCount: 2, runnerCount: 7
        ))
        XCTAssertEqual(update.title, "Amp 2.0.0 is available")
        XCTAssertEqual(update.body, "Update 2 Amp installations used by 7 runners.")
        XCTAssertEqual(update.category, .updateAvailable)
        XCTAssertEqual(update.actions, [.installUpdate, .openUpdates])

        let restart = RunnerUpdateNotificationBuilder.build(.restartRequired(
            version: AmpVersion("2.0.0")!, runnerCount: 3, idleCount: 1,
            workingCount: 2, automaticallyRestartsWhenIdle: false
        ))
        XCTAssertEqual(restart.body, "3 runners need a restart: 1 idle, 2 working.")
        XCTAssertEqual(restart.category, .restartRequired)
        XCTAssertEqual(restart.actions, [.restartAllWhenIdle, .openUpdates])
    }

    func testAutomaticRestartContentSummarizesProgressAndOnlyOpensUpdates() {
        let content = RunnerUpdateNotificationBuilder.build(.restartRequired(
            version: AmpVersion("2.0.0")!, runnerCount: 3, idleCount: 1,
            workingCount: 2, automaticallyRestartsWhenIdle: true
        ))
        XCTAssertEqual(content.body, "1 runner restarted; 2 pending until idle.")
        XCTAssertEqual(content.actions, [.openUpdates])
    }

    @MainActor
    func testPersistentDedupeDoesNotDependOnDeliveryAuthorization() throws {
        let suite = "RunnerUpdateNotificationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts = [RunnerUpdateNotificationRequest]()
        let notifier = RunnerNotifier(defaults: defaults, deliverUpdate: { request in
            attempts.append(request)
            return false
        })
        let input = AmpUpdateNotificationInput(
            latestVersion: AmpVersion("2.0.0"), outdatedExecutableCount: 1,
            affectedRunnerCount: 4, restartRequiredRunnerCount: 0,
            idleRunnerCount: 0, workingRunnerCount: 0,
            automaticallyRestartsWhenIdle: false
        )
        notifier.notifyUpdates(input: input, enabled: true)
        XCTAssertEqual(attempts.count, 1)

        let relaunched = RunnerNotifier(defaults: defaults, deliverUpdate: { request in
            attempts.append(request)
            return true
        })
        relaunched.notifyUpdates(input: input, enabled: true)
        XCTAssertEqual(attempts.count, 1, "a denied system delivery must not cause repeated prompts")
    }

    @MainActor
    func testUpdatePreferenceIsIndependentFromLifecyclePreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "com.riyex.amprunner.notificationsEnabled")
        var updates = [RunnerUpdateNotificationRequest]()
        let notifier = RunnerNotifier(defaults: defaults, deliverUpdate: { request in
            updates.append(request); return true
        })
        notifier.notifyUpdates(input: .init(
            latestVersion: AmpVersion("2.0.0"), outdatedExecutableCount: 1,
            affectedRunnerCount: 1, restartRequiredRunnerCount: 0,
            idleRunnerCount: 0, workingRunnerCount: 0,
            automaticallyRestartsWhenIdle: false
        ), enabled: false)
        XCTAssertTrue(notifier.isEnabled)
        XCTAssertTrue(updates.isEmpty)
    }

    @MainActor
    func testUpdateActionsRouteWithoutThreadData() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let notifier = RunnerNotifier(defaults: defaults, deliverUpdate: { _ in true })
        var actions = [RunnerNotificationAction]()
        notifier.actionHandler = { actions.append($0) }
        notifier.handleUpdateAction(.installUpdate)
        notifier.handleUpdateAction(.restartAllWhenIdle)
        notifier.handleUpdateAction(.openUpdates)
        notifier.handleUpdateAction(.defaultOpen)
        XCTAssertEqual(actions, [.installUpdate, .restartAllWhenIdle, .openUpdates, .openUpdates])
    }
}
