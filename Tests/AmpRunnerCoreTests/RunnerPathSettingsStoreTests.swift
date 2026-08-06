import Foundation
import XCTest
@testable import AmpRunnerCore

final class RunnerPathSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RunnerPathSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadReturnsEmptySettingsWhenKeyIsAbsent() throws {
        let store = RunnerPathSettingsStore(defaults: defaults, key: "settings")

        XCTAssertEqual(try store.load(), RunnerPathSettings())
    }

    func testSaveThenLoadRoundTripsOrderedDirectoriesAndStringsExactly() throws {
        let store = RunnerPathSettingsStore(defaults: defaults, key: "settings")
        let original = RunnerPathSettings(
            userDirectories: ["~/bin", "/Applications/Tool Bin", "/tools/./bin"]
        )

        try store.save(original)

        XCTAssertEqual(try store.load(), original)
    }

    func testLoadThrowsForMalformedJSONDataWithoutChangingPersistedBytes() {
        let key = "settings"
        let malformedData = Data("not valid JSON".utf8)
        defaults.set(malformedData, forKey: key)
        let store = RunnerPathSettingsStore(defaults: defaults, key: key)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? RunnerPathSettingsStoreError, .invalidSettingsData)
        }
        XCTAssertEqual(defaults.data(forKey: key), malformedData)
    }

    func testLoadThrowsWhenPersistedValueHasWrongType() {
        let key = "settings"
        defaults.set("not data", forKey: key)
        let store = RunnerPathSettingsStore(defaults: defaults, key: key)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .wrongPersistedValueType = error as? RunnerPathSettingsStoreError else {
                return XCTFail("expected wrongPersistedValueType, got \(error)")
            }
        }
    }

    func testLoadThrowsForSchemaIncompatibleJSONWithoutChangingPersistedBytes() {
        let key = "settings"
        let incompatibleData = Data(#"{"userDirectories":"not-an-array"}"#.utf8)
        defaults.set(incompatibleData, forKey: key)
        let store = RunnerPathSettingsStore(defaults: defaults, key: key)

        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: incompatibleData))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? RunnerPathSettingsStoreError, .invalidSettingsData)
        }
        XCTAssertEqual(defaults.data(forKey: key), incompatibleData)
    }

    func testStoresWithDifferentDefaultsAndKeysDoNotCrossContaminate() throws {
        let secondSuiteName = "RunnerPathSettingsStoreTests.\(UUID().uuidString)"
        guard let secondDefaults = UserDefaults(suiteName: secondSuiteName) else {
            return XCTFail("expected isolated UserDefaults suite")
        }
        defer { secondDefaults.removePersistentDomain(forName: secondSuiteName) }

        let first = RunnerPathSettingsStore(defaults: defaults, key: "first")
        let second = RunnerPathSettingsStore(defaults: defaults, key: "second")
        let third = RunnerPathSettingsStore(defaults: secondDefaults, key: "first")

        try first.save(RunnerPathSettings(userDirectories: ["/first"]))
        try second.save(RunnerPathSettings(userDirectories: ["/second"]))
        try third.save(RunnerPathSettings(userDirectories: ["/third"]))

        XCTAssertEqual(try first.load().userDirectories, ["/first"])
        XCTAssertEqual(try second.load().userDirectories, ["/second"])
        XCTAssertEqual(try third.load().userDirectories, ["/third"])
    }
}
