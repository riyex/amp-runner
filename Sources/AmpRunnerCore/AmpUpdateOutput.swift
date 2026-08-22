import Foundation

public enum AmpUpdateOutput: Equatable, Sendable {
    case updated(AmpVersion)
    case noUpdateNeeded

    public static func parse(_ output: String) throws -> Self {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "no update needed" { return .noUpdateNeeded }

        let prefix = "updated "
        if value.hasPrefix(prefix),
           let version = AmpVersion(String(value.dropFirst(prefix.count))) {
            return .updated(version)
        }
        throw AmpUpdateOutputParseError.invalidOutput(value)
    }
}

public enum AmpUpdateOutputParseError: Error, Equatable, LocalizedError, Sendable {
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidOutput(value):
            return value.isEmpty
                ? "Amp returned empty update output."
                : "Amp returned invalid update output: \(value)"
        }
    }
}
