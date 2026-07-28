import Foundation

/// Reads and edits the single Amp setting this app cares about:
/// `amp.remoteThreadCreation.enabled` in `~/.config/amp/settings.json`.
///
/// Deliberately takes the file *contents* rather than a path so the logic is pure and
/// testable; the app layer does the reading and writing.
public enum AmpSettingsChecker {

    public static let remoteThreadCreationKey = "amp.remoteThreadCreation.enabled"

    public enum Result: Equatable, Sendable {
        /// The key is present and `true`.
        case enabled
        /// The key is present and `false`.
        case disabled
        /// The file parses but has no such key — Amp's own default applies.
        case notConfigured
        /// The file exists but is not valid JSON, or is not a JSON object.
        case malformed(String)
        /// No settings file at all.
        case missingFile

        public var isEnabled: Bool { self == .enabled }

        /// Whether the app should show the "remote thread creation isn't enabled"
        /// warning. Malformed files are surfaced too — silently rewriting a file we
        /// could not parse would destroy the user's settings.
        public var needsAttention: Bool { self != .enabled }

        public var userFacingMessage: String {
            switch self {
            case .enabled:
                return "Remote thread creation is enabled."
            case .disabled:
                return "Remote thread creation is disabled in ~/.config/amp/settings.json. Runners will start, but ampcode.com will not be able to create threads on them."
            case .notConfigured:
                return "\(remoteThreadCreationKey) is not set in ~/.config/amp/settings.json. Enable it so ampcode.com can create threads on your runners."
            case .malformed(let detail):
                return "~/.config/amp/settings.json could not be parsed (\(detail)). Fix it by hand — Amp Runner will not overwrite a file it cannot read."
            case .missingFile:
                return "No ~/.config/amp/settings.json found. Create it to enable remote thread creation."
            }
        }
    }

    /// Default location of Amp's settings file.
    public static func defaultSettingsURL(homeDirectoryPath: String) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public static func check(settingsData: Data?) -> Result {
        guard let settingsData else { return .missingFile }

        let trimmed = String(decoding: settingsData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .notConfigured }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: settingsData, options: [])
        } catch {
            return .malformed(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            return .malformed("top-level value is not a JSON object")
        }

        guard let raw = dictionary[remoteThreadCreationKey] else { return .notConfigured }
        if let flag = raw as? Bool { return flag ? .enabled : .disabled }
        if let number = raw as? NSNumber { return number.boolValue ? .enabled : .disabled }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return .enabled
            default: return .disabled
            }
        }
        return .malformed("\(remoteThreadCreationKey) is not a boolean")
    }

    public static func check(settingsJSON: String?) -> Result {
        guard let settingsJSON else { return .missingFile }
        return check(settingsData: Data(settingsJSON.utf8))
    }

    public enum MergeError: Error, Equatable, CustomStringConvertible {
        case malformed(String)

        public var description: String {
            switch self {
            case .malformed(let detail):
                return "Refusing to rewrite ~/.config/amp/settings.json: \(detail)."
            }
        }
    }

    /// Returns the settings file contents with `amp.remoteThreadCreation.enabled` set
    /// to `enabled`, **preserving every other key**. A missing or empty file produces a
    /// fresh single-key object; an unparseable file throws rather than clobbering it.
    public static func settingsEnablingRemoteThreadCreation(
        existing: Data?,
        enabled: Bool = true
    ) throws -> Data {
        var dictionary: [String: Any] = [:]

        if let existing {
            let trimmed = String(decoding: existing, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let object: Any
                do {
                    object = try JSONSerialization.jsonObject(with: existing, options: [])
                } catch {
                    throw MergeError.malformed(error.localizedDescription)
                }
                guard let parsed = object as? [String: Any] else {
                    throw MergeError.malformed("top-level value is not a JSON object")
                }
                dictionary = parsed
            }
        }

        dictionary[remoteThreadCreationKey] = enabled
        return try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// String convenience over `settingsEnablingRemoteThreadCreation(existing:enabled:)`.
    public static func settingsJSONEnablingRemoteThreadCreation(
        existing: String?,
        enabled: Bool = true
    ) throws -> String {
        let data = try settingsEnablingRemoteThreadCreation(
            existing: existing.map { Data($0.utf8) },
            enabled: enabled
        )
        return String(decoding: data, as: UTF8.self)
    }
}
