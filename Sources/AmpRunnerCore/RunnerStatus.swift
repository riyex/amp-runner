import Foundation

/// Supervision state of a single runner process.
///
/// Label choice (documented once, used everywhere): the connected-but-not-executing
/// state is displayed as **"Online"**, not "Idle". "Idle" is treated purely as a
/// synonym appearing in Amp's own log output, never as a distinct UI state.
public enum RunnerStatus: Equatable, Hashable, Sendable {
    /// No process is running.
    case stopped
    /// The process was spawned but has not yet reported that it is connected.
    case starting
    /// Connected to ampcode.com and waiting for remote threads.
    case online
    /// Currently executing a remote thread.
    case working
    /// Terminated abnormally, or reported a failure. Payload is human-readable.
    case error(String)

    /// Short label for the menu bar.
    public var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .online: return "Online"
        case .working: return "Working"
        case .error: return "Error"
        }
    }

    /// Label plus the failure reason, when there is one.
    public var detailedDescription: String {
        switch self {
        case .error(let message) where !message.isEmpty:
            return "Error: \(message)"
        default:
            return displayName
        }
    }

    /// A coloured dot suitable for a plain-text menu item.
    public var symbolName: String {
        switch self {
        case .stopped: return "circle"
        case .starting: return "circle.dotted"
        case .online: return "circle.fill"
        case .working: return "bolt.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    /// True when a process is expected to be alive.
    public var isRunning: Bool {
        switch self {
        case .starting, .online, .working: return true
        case .stopped, .error: return false
        }
    }
}

/// Aggregate status used by the menu bar item when multiple runners disagree.
public enum RunnerAggregateStatus: Equatable, Hashable, Sendable {
    case stopped
    case starting
    case online
    case working
    case error

    public var accessibilityDescription: String {
        switch self {
        case .stopped: return "all runners stopped"
        case .starting: return "runner starting"
        case .online: return "runner online"
        case .working: return "runner working"
        case .error: return "runner error"
        }
    }
}

extension RunnerStatus {
    /// Brand precedence for the menu bar aggregate indicator:
    /// error > working > starting > online > stopped.
    public static func menuBarAggregateStatus(for statuses: [RunnerStatus]) -> RunnerAggregateStatus {
        if statuses.contains(where: { if case .error = $0 { return true } else { return false } }) {
            return .error
        }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.starting) { return .starting }
        if statuses.contains(.online) { return .online }
        return .stopped
    }
}

extension RunnerStatus: CustomStringConvertible {
    public var description: String { detailedDescription }
}
