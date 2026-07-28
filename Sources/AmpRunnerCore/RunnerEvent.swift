import Foundation

/// A single meaningful thing observed on a runner's stdout/stderr stream.
public enum RunnerEvent: Equatable, Hashable, Sendable {
    case statusChanged(RunnerStatus)
    case threadStarted
    case threadFinished
    case threadFailed(String)
    case unrecognizedLine(String)

    /// The status a supervisor should move to because of this event, if any.
    ///
    /// `unrecognizedLine` deliberately implies nothing — an unmatched line must never
    /// change state, because the matcher table is heuristic.
    public var impliedStatus: RunnerStatus? {
        switch self {
        case .statusChanged(let status): return status
        case .threadStarted: return .working
        case .threadFinished: return .online
        case .threadFailed(let message): return .error(message)
        case .unrecognizedLine: return nil
        }
    }

    /// Whether this event is worth surfacing as a user notification.
    public var isNotifiable: Bool {
        switch self {
        case .threadStarted, .threadFinished, .threadFailed: return true
        case .statusChanged, .unrecognizedLine: return false
        }
    }
}
