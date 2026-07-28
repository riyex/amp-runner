import Foundation

/// The only file-system touch point of the store, injected so tests can use an
/// in-memory fake.
public protocol ProfileStoreFileIO {
    /// Returns `nil` when the file does not exist yet (first launch).
    func read(from url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
}

/// `FileManager`-backed implementation. Creates intermediate directories on write.
public struct FileManagerProfileStoreIO: ProfileStoreFileIO {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func read(from url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try data.write(to: url, options: .atomic)
    }
}

/// Loads and saves `[RunnerProfile]` as JSON.
///
/// Only non-secret configuration is persisted. No Keychain access, no tokens, no
/// credentials of any kind ever pass through this type.
public final class RunnerProfileStore {
    public let fileURL: URL
    private let io: ProfileStoreFileIO
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, io: ProfileStoreFileIO) {
        self.fileURL = fileURL
        self.io = io

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Default on-disk location: `~/Library/Application Support/AmpRunner/profiles.json`.
    ///
    /// Passed in rather than read from the environment so the logic stays portable and
    /// testable; the app supplies `FileManager.default.homeDirectoryForCurrentUser`.
    public static func defaultFileURL(homeDirectoryPath: String) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AmpRunner", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    /// Returns an empty array when nothing has been saved yet.
    public func load() throws -> [RunnerProfile] {
        guard let data = try io.read(from: fileURL), !data.isEmpty else { return [] }
        return try decoder.decode([RunnerProfile].self, from: data)
    }

    /// Validates the whole collection before writing anything, so a rejected save
    /// leaves the previous file untouched.
    public func save(_ profiles: [RunnerProfile]) throws {
        try RunnerProfileStore.validate(profiles)
        try io.write(try encoder.encode(profiles), to: fileURL)
    }

    /// Inserts or replaces `profile` by `id`, then saves the result.
    @discardableResult
    public func upsert(_ profile: RunnerProfile, into profiles: [RunnerProfile]) throws -> [RunnerProfile] {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        try save(updated)
        return updated
    }

    @discardableResult
    public func delete(id: UUID, from profiles: [RunnerProfile]) throws -> [RunnerProfile] {
        let updated = profiles.filter { $0.id != id }
        try save(updated)
        return updated
    }

    // MARK: - Validation

    /// Enforces the "one profile, one isolated working directory" rule as well as
    /// per-field validity. Comparison is done on standardised paths so
    /// `/a/b`, `/a/b/`, and `/a/./b` are recognised as the same directory.
    public static func validate(_ profiles: [RunnerProfile]) throws {
        var seenDirectories: Set<String> = []
        var seenRunnerIDs: Set<String> = []

        for profile in profiles {
            try profile.validateFields()

            let directory = normalizedDirectoryKey(profile.workingDirectoryPath)
            guard seenDirectories.insert(directory).inserted else {
                throw RunnerProfileValidationError.duplicateWorkingDirectory(profile.workingDirectoryPath)
            }

            let runnerID = profile.runnerID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard seenRunnerIDs.insert(runnerID).inserted else {
                throw RunnerProfileValidationError.duplicateRunnerID(profile.runnerID)
            }
        }
    }

    /// Convenience used by the editor: would adding/updating this profile collide with
    /// an existing one?
    public static func validateCandidate(
        _ candidate: RunnerProfile,
        against existing: [RunnerProfile]
    ) throws {
        try candidate.validateFields()
        let others = existing.filter { $0.id != candidate.id }
        try validate(others + [candidate])
    }

    static func normalizedDirectoryKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let standardized = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }
}
