import Foundation

public enum AmpUpdatePreferencesStoreError: Error, Equatable, LocalizedError {
    case wrongPersistedValueType(String)
    case invalidPreferencesData

    public var errorDescription: String? {
        switch self {
        case .wrongPersistedValueType(let type):
            return "Amp update preferences must be stored as JSON data, but found \(type)."
        case .invalidPreferencesData:
            return "Amp update preferences contain invalid or incompatible JSON data."
        }
    }
}

public final class AmpUpdatePreferencesStore {
    public static let defaultKey = "com.riyex.amprunner.ampUpdatePreferences"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> AmpUpdatePreferences {
        guard let value = defaults.object(forKey: key) else { return AmpUpdatePreferences() }
        guard let data = value as? Data else {
            throw AmpUpdatePreferencesStoreError.wrongPersistedValueType(String(reflecting: type(of: value)))
        }
        guard let preferences = try? JSONDecoder().decode(AmpUpdatePreferences.self, from: data) else {
            throw AmpUpdatePreferencesStoreError.invalidPreferencesData
        }
        return preferences
    }

    public func save(_ preferences: AmpUpdatePreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: key)
    }
}
