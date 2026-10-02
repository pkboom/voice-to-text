/// Pure hold-to-talk decision logic over monotonic instants.
///
/// - A hold shorter than `minimumHold` (default 300 ms) is discarded (`.tooShort`).
/// - Another key pressed while held cancels the hold (`.chordCancel`).
/// - A hold reaching `maximumHold` (default 90 s) is force-ended (`.forceEnd`); the audio is still
///   processed and the later key-up is ignored.
public struct HoldFilter: Sendable {
    public enum Decision: Sendable, Equatable {
        case ignored
        case started
        case accepted(Duration)
        case tooShort(Duration)
        case chordCancel
        case forceEnd(Duration)
    }

    public static let defaultMinimumHold: Duration = .milliseconds(300)
    public static let defaultMaximumHold: Duration = .seconds(90)

    public let minimumHold: Duration
    public let maximumHold: Duration
    public private(set) var heldSince: MonotonicInstant?

    public init(minimumHold: Duration = defaultMinimumHold, maximumHold: Duration = defaultMaximumHold) {
        self.minimumHold = minimumHold
        self.maximumHold = maximumHold
    }

    public var isHeld: Bool { heldSince != nil }

    /// When the current hold will be force-ended.
    public var deadline: MonotonicInstant? { heldSince?.advanced(by: maximumHold) }

    public mutating func keyDown(at instant: MonotonicInstant) -> Decision {
        guard heldSince == nil else { return .ignored }
        heldSince = instant
        return .started
    }

    public mutating func keyUp(at instant: MonotonicInstant) -> Decision {
        guard let start = heldSince else { return .ignored }
        heldSince = nil
        let held = instant - start
        return held >= minimumHold ? .accepted(held) : .tooShort(held)
    }

    public mutating func chord(at instant: MonotonicInstant) -> Decision {
        guard heldSince != nil else { return .ignored }
        heldSince = nil
        return .chordCancel
    }

    public mutating func checkTimeout(at instant: MonotonicInstant) -> Decision {
        guard let start = heldSince, instant - start >= maximumHold else { return .ignored }
        heldSince = nil
        return .forceEnd(instant - start)
    }
}
