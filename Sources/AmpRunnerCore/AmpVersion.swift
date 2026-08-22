import Foundation

public struct AmpVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let originalString: String

    private let numericComponents: [Int]
    private let prerelease: String?

    public init?(_ string: String) {
        let pieces = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericStrings = pieces[0].split(separator: ".", omittingEmptySubsequences: false)

        guard numericStrings.count >= 2,
              numericStrings.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let components = Optional(numericStrings.compactMap({ Int($0) })),
              components.count == numericStrings.count else {
            return nil
        }

        if pieces.count == 2 && (pieces[1].isEmpty || pieces[1].contains(where: \.isWhitespace)) {
            return nil
        }
        guard !string.contains(where: \.isWhitespace) else { return nil }

        var normalized = components
        while normalized.count > 2 && normalized.last == 0 {
            normalized.removeLast()
        }

        originalString = string
        numericComponents = normalized
        prerelease = pieces.count == 2 ? String(pieces[1]) : nil
    }

    public var description: String { originalString }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.numericComponents == rhs.numericComponents && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
        for index in 0..<count {
            let left = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
            let right = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case let (.some(left), .some(right)): return left < right
        case (.some, .none): return true
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(numericComponents)
        hasher.combine(prerelease)
    }
}

public enum AmpVersionParseError: Error, Equatable, LocalizedError, Sendable {
    case emptyOutput
    case invalidUTF8
    case invalidVersion(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput: return "Amp returned empty version output."
        case .invalidUTF8: return "Amp returned version data that is not valid UTF-8."
        case let .invalidVersion(value): return "Amp returned an invalid version: \(value)"
        }
    }
}

public enum AmpReleaseResponse {
    public static func parse(_ data: Data) throws -> AmpVersion {
        guard let output = String(data: data, encoding: .utf8) else {
            throw AmpVersionParseError.invalidUTF8
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AmpVersionParseError.emptyOutput }
        guard let version = AmpVersion(value) else {
            throw AmpVersionParseError.invalidVersion(value)
        }
        return version
    }
}

public enum AmpVersionCommandOutput {
    public static func parse(_ output: String) throws -> AmpVersion {
        guard let token = output.split(whereSeparator: \.isWhitespace).first else {
            throw AmpVersionParseError.emptyOutput
        }
        let value = String(token)
        guard let version = AmpVersion(value) else {
            throw AmpVersionParseError.invalidVersion(value)
        }
        return version
    }
}
