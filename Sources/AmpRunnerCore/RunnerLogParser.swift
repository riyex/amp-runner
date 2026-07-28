import Foundation

/// Maps one raw log line to a `RunnerEvent`.
///
/// **Heuristic — treat as best-effort.** Amp's runner-mode console output is not a
/// documented, stable interface; the phrases below were observed in a Sourcegraph demo
/// and may change between Amp versions. That is why the matcher table is isolated here
/// as plain data: adding or correcting a phrase is a one-line change and never touches
/// the supervisor. Process-alive / exit-code detection is handled separately and is
/// always authoritative — see ARCHITECTURE.md.
public struct RunnerLogParser: Sendable {

    /// A single substring-based rule. Matching is case-insensitive on the whole line.
    public struct Matcher: Sendable {
        /// Every phrase must be present for the rule to fire.
        public let phrases: [String]
        /// Any of these phrases disqualifies the line.
        public let excludedPhrases: [String]
        /// Produces the event; receives the original (untrimmed-case) line.
        public let makeEvent: @Sendable (String) -> RunnerEvent

        public init(
            phrases: [String],
            excludedPhrases: [String] = [],
            makeEvent: @escaping @Sendable (String) -> RunnerEvent
        ) {
            self.phrases = phrases
            self.excludedPhrases = excludedPhrases
            self.makeEvent = makeEvent
        }

        public func matches(lowercasedLine: String) -> Bool {
            guard !phrases.isEmpty else { return false }
            for excluded in excludedPhrases where lowercasedLine.contains(excluded.lowercased()) {
                return false
            }
            return phrases.allSatisfy { lowercasedLine.contains($0.lowercased()) }
        }
    }

    public let matchers: [Matcher]

    public init(matchers: [Matcher] = RunnerLogParser.defaultMatchers) {
        self.matchers = matchers
    }

    /// Returns `nil` for blank lines only. Every other line yields at least
    /// `.unrecognizedLine`, so the log viewer never silently drops content.
    public func parse(line: String) -> RunnerEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        for matcher in matchers where matcher.matches(lowercasedLine: lowercased) {
            return matcher.makeEvent(trimmed)
        }
        return .unrecognizedLine(trimmed)
    }

    /// Ordered most-specific first. Failure and completion rules must precede the
    /// generic "connected" rule so a line mentioning both is classified correctly.
    public static let defaultMatchers: [Matcher] = [
        // --- Failures -------------------------------------------------------
        Matcher(phrases: ["thread failed"]) { .threadFailed($0) },
        Matcher(phrases: ["failed to run thread"]) { .threadFailed($0) },
        Matcher(phrases: ["error"], excludedPhrases: ["0 errors", "no errors"]) { .threadFailed($0) },
        Matcher(phrases: ["fatal"]) { .threadFailed($0) },
        Matcher(phrases: ["panic:"]) { .threadFailed($0) },

        // --- Thread lifecycle ----------------------------------------------
        Matcher(phrases: ["thread", "completed"]) { _ in .threadFinished },
        Matcher(phrases: ["thread", "finished"]) { _ in .threadFinished },
        Matcher(phrases: ["finished running thread"]) { _ in .threadFinished },
        Matcher(phrases: ["thread", "started"]) { _ in .threadStarted },
        Matcher(phrases: ["running thread"]) { _ in .threadStarted },
        Matcher(phrases: ["accepted thread"]) { _ in .threadStarted },
        Matcher(phrases: ["new thread"]) { _ in .threadStarted },

        // --- Connection / idle ----------------------------------------------
        Matcher(phrases: ["remote controlling the app runner"]) { _ in .statusChanged(.online) },
        Matcher(phrases: ["waiting for threads"]) { _ in .statusChanged(.online) },
        Matcher(phrases: ["runner", "connected"]) { _ in .statusChanged(.online) },
        Matcher(phrases: ["runner", "ready"]) { _ in .statusChanged(.online) },
        Matcher(phrases: ["listening for"]) { _ in .statusChanged(.online) },

        // --- Disconnection ----------------------------------------------------
        Matcher(phrases: ["disconnected"]) { _ in .statusChanged(.starting) },
        Matcher(phrases: ["reconnecting"]) { _ in .statusChanged(.starting) },

        // --- Shutdown ---------------------------------------------------------
        Matcher(phrases: ["shutting down"]) { _ in .statusChanged(.stopped) }
    ]
}
