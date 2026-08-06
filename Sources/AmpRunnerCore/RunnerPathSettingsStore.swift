import Foundation

public enum RunnerPathSettingsStoreError: Error, Equatable, LocalizedError {
    case wrongPersistedValueType(String)
    case invalidSettingsData

    public var errorDescription: String? {
        switch self {
        case .wrongPersistedValueType(let type):
            return "Runner path settings must be stored as JSON data, but found \(type)."
        case .invalidSettingsData:
            return "Runner path settings contain invalid or incompatible JSON data."
        }
    }
}

public final class RunnerPathSettingsStore {
    public static let defaultKey = "com.riyex.amprunner.runnerPathSettings"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> RunnerPathSettings {
        guard let persistedValue = defaults.object(forKey: key) else {
            return RunnerPathSettings()
        }
        guard let data = persistedValue as? Data else {
            throw RunnerPathSettingsStoreError.wrongPersistedValueType(
                String(reflecting: type(of: persistedValue))
            )
        }

        do {
            return try JSONDecoder().decode(RunnerPathSettings.self, from: data)
        } catch {
            throw RunnerPathSettingsStoreError.invalidSettingsData
        }
    }

    public func save(_ settings: RunnerPathSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }
}
