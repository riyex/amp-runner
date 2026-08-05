import XCTest
@testable import AmpRunnerCore

/// In-memory stand-in for the file system.
final class InMemoryProfileStoreIO: ProfileStoreFileIO {
    private(set) var files: [String: Data] = [:]
    private(set) var writeCount = 0
    var readError: Error?
    var writeError: Error?

    init(seed: [String: Data] = [:]) {
        self.files = seed
    }

    func read(from url: URL) throws -> Data? {
        if let readError { throw readError }
        return files[url.path]
    }

    func write(_ data: Data, to url: URL) throws {
        if let writeError { throw writeError }
        writeCount += 1
        files[url.path] = data
    }
}

final class RunnerProfileStoreTests: XCTestCase {

    private let fileURL = URL(fileURLWithPath: "/tmp/amp-runner-tests/profiles.json")

    private func makeProfile(
        name: String = "Sample Project",
        runnerID: String = "sample-runner",
        directory: String = "/Users/tester/src/sample-project"
    ) -> RunnerProfile {
        RunnerProfile(
            name: name,
            runnerID: runnerID,
            workingDirectoryPath: directory,
            ampExecutablePath: "/opt/homebrew/bin/amp"
        )
    }

    // MARK: - Round trip

    func testLoadReturnsEmptyArrayWhenFileMissing() throws {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        XCTAssertEqual(try store.load(), [])
    }

    func testLoadReturnsEmptyArrayWhenFileIsEmpty() throws {
        let io = InMemoryProfileStoreIO(seed: [fileURL.path: Data()])
        let store = RunnerProfileStore(fileURL: fileURL, io: io)
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveThenLoadRoundTripsAllFields() throws {
        let io = InMemoryProfileStoreIO()
        let store = RunnerProfileStore(fileURL: fileURL, io: io)
        let original = RunnerProfile(
            name: "Sample Project",
            runnerID: "sample-runner",
            workingDirectoryPath: "/Users/tester/src/sample-project",
            ampExecutablePath: "/opt/homebrew/bin/amp",
            arguments: ["--no-tui", "--runner-id", "sample-runner"],
            autoStart: true,
            confirmBeforeStart: false
        )

        try store.save([original])
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, original)
        XCTAssertEqual(loaded.first?.autoStart, true)
        XCTAssertEqual(loaded.first?.confirmBeforeStart, false)
    }

    func testSavedJSONIsHumanReadableAndContainsNoSecrets() throws {
        let io = InMemoryProfileStoreIO()
        let store = RunnerProfileStore(fileURL: fileURL, io: io)
        try store.save([makeProfile()])

        let json = String(decoding: try XCTUnwrap(io.files[fileURL.path]), as: UTF8.self)
        XCTAssertTrue(json.contains("\"runnerID\""))
        XCTAssertTrue(json.contains("sample-runner"))
        XCTAssertTrue(json.contains("\n"), "expected pretty-printed JSON")
        for forbidden in ["token", "secret", "password", "refresh"] {
            XCTAssertFalse(json.lowercased().contains(forbidden), "unexpected \(forbidden) in persisted JSON")
        }
    }

    func testLoadSurfacesDecodingErrors() {
        let io = InMemoryProfileStoreIO(seed: [fileURL.path: Data("not json".utf8)])
        let store = RunnerProfileStore(fileURL: fileURL, io: io)
        XCTAssertThrowsError(try store.load())
    }

    // MARK: - Upsert / delete

    func testUpsertAppendsNewProfile() throws {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let first = makeProfile()
        let second = makeProfile(name: "Other", runnerID: "other", directory: "/Users/tester/src/other")

        let result = try store.upsert(second, into: [first])
        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func testUpsertReplacesExistingProfileInPlace() throws {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let first = makeProfile()
        let second = makeProfile(name: "Other", runnerID: "other", directory: "/Users/tester/src/other")

        var edited = first
        edited.name = "Sample Project (renamed)"

        let result = try store.upsert(edited, into: [first, second])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "Sample Project (renamed)")
        XCTAssertEqual(result[1].id, second.id)
    }

    func testDeleteRemovesOnlyTheMatchingProfile() throws {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let first = makeProfile()
        let second = makeProfile(name: "Other", runnerID: "other", directory: "/Users/tester/src/other")

        let result = try store.delete(id: first.id, from: [first, second])
        XCTAssertEqual(result.map(\.id), [second.id])
    }

    // MARK: - Validation

    func testDuplicateWorkingDirectoryIsRejected() {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let a = makeProfile(runnerID: "a", directory: "/Users/tester/src/sample-project")
        let b = makeProfile(name: "B", runnerID: "b", directory: "/Users/tester/src/sample-project")

        XCTAssertThrowsError(try store.save([a, b])) { error in
            XCTAssertEqual(
                error as? RunnerProfileValidationError,
                .duplicateWorkingDirectory("/Users/tester/src/sample-project")
            )
        }
    }

    func testDuplicateWorkingDirectoryDetectionIgnoresTrailingSlashAndDotComponents() {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let a = makeProfile(runnerID: "a", directory: "/Users/tester/src/sample-project")
        let b = makeProfile(name: "B", runnerID: "b", directory: "/Users/tester/./src/sample-project/")

        XCTAssertThrowsError(try store.save([a, b]))
    }

    func testDuplicateRunnerIDIsRejected() {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let a = makeProfile(directory: "/Users/tester/src/one")
        let b = makeProfile(name: "B", directory: "/Users/tester/src/two")

        XCTAssertThrowsError(try store.save([a, b])) { error in
            XCTAssertEqual(
                error as? RunnerProfileValidationError,
                .duplicateRunnerID("sample-runner")
            )
        }
    }

    func testDistinctDirectoriesAndIDsAreAccepted() throws {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        let a = makeProfile(runnerID: "a", directory: "/Users/tester/src/one")
        let b = makeProfile(name: "B", runnerID: "b", directory: "/Users/tester/src/two")
        XCTAssertNoThrow(try store.save([a, b]))
        XCTAssertEqual(try store.load().count, 2)
    }

    func testEmptyWorkingDirectoryIsRejected() {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        XCTAssertThrowsError(try store.save([makeProfile(directory: "  ")])) { error in
            XCTAssertEqual(error as? RunnerProfileValidationError, .emptyWorkingDirectory)
        }
    }

    func testEmptyNameIsRejected() {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        XCTAssertThrowsError(try store.save([makeProfile(name: " ")])) { error in
            XCTAssertEqual(error as? RunnerProfileValidationError, .emptyName)
        }
    }

    func testEmptyRunnerIDIsRejected() {
        let store = RunnerProfileStore(fileURL: fileURL, io: InMemoryProfileStoreIO())
        XCTAssertThrowsError(try store.save([makeProfile(runnerID: "")])) { error in
            XCTAssertEqual(error as? RunnerProfileValidationError, .emptyRunnerID)
        }
    }

    func testRejectedSaveDoesNotTouchTheFile() throws {
        let io = InMemoryProfileStoreIO()
        let store = RunnerProfileStore(fileURL: fileURL, io: io)
        let good = makeProfile()
        try store.save([good])
        XCTAssertEqual(io.writeCount, 1)

        let clash = makeProfile(name: "B", runnerID: "b", directory: good.workingDirectoryPath)
        XCTAssertThrowsError(try store.save([good, clash]))

        XCTAssertEqual(io.writeCount, 1, "a rejected save must not write")
        XCTAssertEqual(try store.load(), [good])
    }

    func testValidateCandidateIgnoresTheProfileBeingEdited() throws {
        let existing = makeProfile()
        var edited = existing
        edited.name = "Renamed"
        // Same id, same directory — must not be treated as a duplicate of itself.
        XCTAssertNoThrow(try RunnerProfileStore.validateCandidate(edited, against: [existing]))
    }

    func testValidateCandidateRejectsCollisionWithAnotherProfile() {
        let existing = makeProfile()
        let candidate = makeProfile(
            name: "New",
            runnerID: "new",
            directory: existing.workingDirectoryPath
        )
        XCTAssertThrowsError(try RunnerProfileStore.validateCandidate(candidate, against: [existing]))
    }

    // MARK: - Default location

    func testDefaultFileURLLivesInApplicationSupport() {
        XCTAssertEqual(
            RunnerProfileStore.defaultFileURL(homeDirectoryPath: "/Users/tester").path,
            "/Users/tester/Library/Application Support/AmpRunner/profiles.json"
        )
    }

    // MARK: - Real FileManager IO

    func testFileManagerIOCreatesIntermediateDirectoriesAndRoundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("amp-runner-io-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("profiles.json")
        let io = FileManagerProfileStoreIO()

        XCTAssertNil(try io.read(from: target))
        try io.write(Data("[]".utf8), to: target)
        XCTAssertEqual(try io.read(from: target), Data("[]".utf8))

        let store = RunnerProfileStore(fileURL: target, io: io)
        let profile = makeProfile()
        try store.save([profile])
        XCTAssertEqual(try store.load(), [profile])
    }
}
