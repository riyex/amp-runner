import Foundation
import XCTest
@testable import AmpRunnerCore

final class AmpUpdatePreferencesStoreTests: XCTestCase {
    func testDefaultsMatchApprovedValues() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(try AmpUpdatePreferencesStore(defaults: defaults).load(), AmpUpdatePreferences())
        XCTAssertEqual(AmpUpdatePreferences(), AmpUpdatePreferences(
            automaticallyChecksForUpdates: true,
            sendsUpdateNotifications: true,
            automaticallyInstallsUpdates: false,
            restartsUpdatedRunnersWhenIdle: false
        ))
    }

    func testRoundTripsAllValues() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmpUpdatePreferencesStore(defaults: defaults, key: "preferences")
        let value = AmpUpdatePreferences(
            automaticallyChecksForUpdates: false,
            sendsUpdateNotifications: false,
            automaticallyInstallsUpdates: true,
            restartsUpdatedRunnersWhenIdle: true
        )

        try store.save(value)

        XCTAssertEqual(try store.load(), value)
    }

    func testMalformedDataIsRejectedWithoutOverwrite() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("bad json".utf8)
        defaults.set(data, forKey: "preferences")

        XCTAssertThrowsError(try AmpUpdatePreferencesStore(defaults: defaults, key: "preferences").load()) {
            XCTAssertEqual($0 as? AmpUpdatePreferencesStoreError, .invalidPreferencesData)
        }
        XCTAssertEqual(defaults.data(forKey: "preferences"), data)
    }

    func testWrongStoredTypeIsRejectedWithoutOverwrite() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bad type", forKey: "preferences")

        XCTAssertThrowsError(try AmpUpdatePreferencesStore(defaults: defaults, key: "preferences").load()) {
            guard case .wrongPersistedValueType = $0 as? AmpUpdatePreferencesStoreError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertEqual(defaults.string(forKey: "preferences"), "bad type")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AmpUpdatePreferencesStoreTests.\(UUID())"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
