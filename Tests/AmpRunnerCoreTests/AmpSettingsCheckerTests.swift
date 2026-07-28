import XCTest
@testable import AmpRunnerCore

final class AmpSettingsCheckerTests: XCTestCase {

    private let key = AmpSettingsChecker.remoteThreadCreationKey

    // MARK: - Reading

    func testMissingFileIsReported() {
        XCTAssertEqual(AmpSettingsChecker.check(settingsData: nil), .missingFile)
        XCTAssertEqual(AmpSettingsChecker.check(settingsJSON: nil), .missingFile)
    }

    func testEmptyFileIsNotConfigured() {
        XCTAssertEqual(AmpSettingsChecker.check(settingsJSON: "   \n "), .notConfigured)
    }

    func testEnabledTrue() {
        XCTAssertEqual(
            AmpSettingsChecker.check(settingsJSON: #"{"amp.remoteThreadCreation.enabled": true}"#),
            .enabled
        )
    }

    func testEnabledFalse() {
        XCTAssertEqual(
            AmpSettingsChecker.check(settingsJSON: #"{"amp.remoteThreadCreation.enabled": false}"#),
            .disabled
        )
    }

    func testKeyAbsentAmongOtherKeys() {
        XCTAssertEqual(
            AmpSettingsChecker.check(settingsJSON: #"{"amp.somethingElse": 1}"#),
            .notConfigured
        )
    }

    func testStringTrueIsAccepted() {
        XCTAssertEqual(
            AmpSettingsChecker.check(settingsJSON: #"{"amp.remoteThreadCreation.enabled": "true"}"#),
            .enabled
        )
    }

    func testStringOtherValueIsDisabled() {
        XCTAssertEqual(
            AmpSettingsChecker.check(settingsJSON: #"{"amp.remoteThreadCreation.enabled": "nope"}"#),
            .disabled
        )
    }

    func testMalformedJSONIsReported() {
        guard case .malformed = AmpSettingsChecker.check(settingsJSON: "{ not json") else {
            return XCTFail("expected .malformed")
        }
    }

    func testNonObjectTopLevelIsMalformed() {
        guard case .malformed = AmpSettingsChecker.check(settingsJSON: "[1, 2, 3]") else {
            return XCTFail("expected .malformed")
        }
    }

    func testNeedsAttentionFlag() {
        XCTAssertFalse(AmpSettingsChecker.Result.enabled.needsAttention)
        XCTAssertTrue(AmpSettingsChecker.Result.disabled.needsAttention)
        XCTAssertTrue(AmpSettingsChecker.Result.notConfigured.needsAttention)
        XCTAssertTrue(AmpSettingsChecker.Result.missingFile.needsAttention)
        XCTAssertTrue(AmpSettingsChecker.Result.malformed("x").needsAttention)
    }

    func testUserFacingMessagesMentionTheSettingsFile() {
        for result: AmpSettingsChecker.Result in [.disabled, .notConfigured, .missingFile, .malformed("x")] {
            XCTAssertTrue(
                result.userFacingMessage.contains("settings.json"),
                "\(result) message should mention settings.json"
            )
        }
    }

    func testDefaultSettingsURL() {
        XCTAssertEqual(
            AmpSettingsChecker.defaultSettingsURL(homeDirectoryPath: "/Users/tester").path,
            "/Users/tester/.config/amp/settings.json"
        )
    }

    // MARK: - Merging

    func testMergeCreatesFileWhenNoneExists() throws {
        let merged = try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: nil)
        XCTAssertEqual(AmpSettingsChecker.check(settingsJSON: merged), .enabled)
    }

    func testMergeCreatesFileFromEmptyContents() throws {
        let merged = try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: "")
        XCTAssertEqual(AmpSettingsChecker.check(settingsJSON: merged), .enabled)
    }

    func testMergePreservesAllOtherKeys() throws {
        let existing = """
        {
          "amp.url": "https://ampcode.com",
          "amp.mcpServers": { "jira": { "command": "npx" } },
          "amp.remoteThreadCreation.enabled": false,
          "editor.tabSize": 2
        }
        """
        let merged = try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: existing)

        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed[key] as? Bool, true)
        XCTAssertEqual(parsed["amp.url"] as? String, "https://ampcode.com")
        XCTAssertEqual(parsed["editor.tabSize"] as? Int, 2)
        let mcp = try XCTUnwrap(parsed["amp.mcpServers"] as? [String: Any])
        let jira = try XCTUnwrap(mcp["jira"] as? [String: Any])
        XCTAssertEqual(jira["command"] as? String, "npx")
    }

    func testMergeCanDisable() throws {
        let merged = try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(
            existing: #"{"amp.remoteThreadCreation.enabled": true}"#,
            enabled: false
        )
        XCTAssertEqual(AmpSettingsChecker.check(settingsJSON: merged), .disabled)
    }

    func testMergeRefusesToClobberMalformedFile() {
        XCTAssertThrowsError(
            try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: "{ not json")
        ) { error in
            guard case AmpSettingsChecker.MergeError.malformed = error else {
                return XCTFail("expected MergeError.malformed, got \(error)")
            }
        }
    }

    func testMergeRefusesNonObjectTopLevel() {
        XCTAssertThrowsError(
            try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: "[1,2]")
        )
    }

    func testMergeIsIdempotent() throws {
        let once = try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: nil)
        let twice = try AmpSettingsChecker.settingsJSONEnablingRemoteThreadCreation(existing: once)
        XCTAssertEqual(once, twice)
    }
}
