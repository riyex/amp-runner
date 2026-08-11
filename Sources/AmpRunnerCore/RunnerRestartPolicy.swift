import Foundation

public enum RunnerRestartDecision: Equatable, Sendable {
    case restart(after: TimeInterval, attempt: Int)
    case stop(message: String)
}

public struct RunnerRestartPolicy: Equatable, Sendable {
    public static let defaultDelays: [TimeInterval] = [2, 5, 15]
    public static let defaultFailureWindow: TimeInterval = 60

    private let delays: [TimeInterval]
    private let failureWindow: TimeInterval
    private var failureDates: [Date] = []

    public init(
        delays: [TimeInterval] = Self.defaultDelays,
        failureWindow: TimeInterval = Self.defaultFailureWindow
    ) {
        self.delays = delays.filter { $0 >= 0 }
        self.failureWindow = max(0, failureWindow)
    }

    public mutating func recordAbnormalExit(at date: Date = Date()) -> RunnerRestartDecision {
        failureDates = failureDates.filter { date.timeIntervalSince($0) <= failureWindow }
        failureDates.append(date)

        let attempt = failureDates.count
        guard attempt <= delays.count else {
            return .stop(message: "restart limit reached after \(delays.count) attempts")
        }

        return .restart(after: delays[attempt - 1], attempt: attempt)
    }

    public mutating func reset() {
        failureDates.removeAll()
    }
}
