import Foundation

/// Best-effort metadata for an Amp thread observed in runner output or `amp threads list`.
///
/// Amp's runner log is the only real-time source available to this app. Fields here are
/// optional because some lines only say "accepted thread", while richer details can be
/// filled in later from `amp threads list --json`.
public struct RunnerThreadDetails: Codable, Equatable, Hashable, Sendable {
    public var id: String?
    public var title: String?
    public var webURLString: String?
    public var treeURLString: String?
    public var messageCount: Int?
    public var updatedAt: Date?

    public init(
        id: String? = nil,
        title: String? = nil,
        webURLString: String? = nil,
        treeURLString: String? = nil,
        messageCount: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = Self.cleaned(id)
        self.title = Self.cleaned(title)
        self.webURLString = Self.cleaned(webURLString)
        self.treeURLString = Self.cleaned(treeURLString)
        self.messageCount = messageCount
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        id == nil
            && title == nil
            && webURLString == nil
            && treeURLString == nil
            && messageCount == nil
            && updatedAt == nil
    }

    public var displayName: String {
        title ?? id ?? "Thread"
    }

    public var projectDisplayName: String? {
        guard let treeURLString else { return nil }
        if let url = URL(string: treeURLString), url.isFileURL {
            return Self.cleaned(url.lastPathComponent)
        }
        return Self.cleaned(URL(fileURLWithPath: treeURLString).lastPathComponent)
    }

    public func merging(_ other: RunnerThreadDetails?) -> RunnerThreadDetails {
        guard let other else { return self }
        return RunnerThreadDetails(
            id: other.id ?? id,
            title: other.title ?? title,
            webURLString: other.webURLString ?? webURLString,
            treeURLString: other.treeURLString ?? treeURLString,
            messageCount: other.messageCount ?? messageCount,
            updatedAt: other.updatedAt ?? updatedAt
        )
    }

    /// Extracts a thread ID and URL from a single Amp log line, when present.
    public static func detected(in line: String) -> RunnerThreadDetails? {
        let id = firstThreadID(in: line)
        let webURLString = firstThreadURL(in: line) ?? id.map { "https://ampcode.com/threads/\($0)" }
        let details = RunnerThreadDetails(id: id, webURLString: webURLString)
        return details.isEmpty ? nil : details
    }

    private static func firstThreadID(in text: String) -> String? {
        guard let range = text.range(
            of: #"T-[0-9A-Za-z][0-9A-Za-z-]*"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return cleaned(String(text[range]))
    }

    private static func firstThreadURL(in text: String) -> String? {
        guard let range = text.range(
            of: #"https?://[^\s<>"']*/threads/T-[0-9A-Za-z][0-9A-Za-z-]*"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return cleaned(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}")))
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// A single meaningful thing observed on a runner's stdout/stderr stream.
public enum RunnerEvent: Equatable, Hashable, Sendable {
    case statusChanged(RunnerStatus)
    case threadStarted(RunnerThreadDetails)
    case threadIdle(RunnerThreadDetails?)
    case threadFinished(RunnerThreadDetails?, duration: TimeInterval?)
    case threadFailed(String, thread: RunnerThreadDetails?, duration: TimeInterval?)
    case unrecognizedLine(String)

    /// The status a supervisor should move to because of this event, if any.
    ///
    /// `unrecognizedLine` deliberately implies nothing — an unmatched line must never
    /// change state, because the matcher table is heuristic.
    public var impliedStatus: RunnerStatus? {
        switch self {
        case .statusChanged(let status): return status
        case .threadStarted: return .working
        case .threadIdle: return .online
        case .threadFinished: return .online
        case .threadFailed(let message, _, _): return .error(message)
        case .unrecognizedLine: return nil
        }
    }

    /// Whether this event is worth surfacing as a user notification.
    public var isNotifiable: Bool {
        switch self {
        case .threadStarted, .threadFinished, .threadFailed: return true
        case .threadIdle, .statusChanged, .unrecognizedLine: return false
        }
    }
}
