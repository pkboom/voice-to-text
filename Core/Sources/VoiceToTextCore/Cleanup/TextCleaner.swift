/// The result of cleaning a raw transcript.
public struct CleanupOutcome: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Identity; no cleanup attempted (v1).
        case passthrough
        /// A cleaner produced the text.
        case cleaned
        /// Cleanup was attempted but failed; `text` is the raw transcript.
        case raw(reason: String)
    }

    public let text: String
    public let source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

/// Post-processes a raw transcript. **Non-throwing**: implementations own their fallback (return
/// the raw text with `.raw(reason:)`), so the pipeline can never lose a dictation.
public protocol TextCleaner: Sendable {
    func clean(_ raw: String) async -> CleanupOutcome
}

/// Identity cleaner wired in v1 (AC14).
public struct PassthroughCleaner: TextCleaner {
    public init() {}

    public func clean(_ raw: String) async -> CleanupOutcome {
        CleanupOutcome(text: raw, source: .passthrough)
    }
}
