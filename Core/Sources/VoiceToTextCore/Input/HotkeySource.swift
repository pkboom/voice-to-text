import Foundation

/// A point on a monotonic timeline, in nanoseconds. Never derived from wall-clock time or
/// `CGEvent.timestamp`; hotkey sources stamp events from a `MonotonicClock` inside their callback.
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public func advanced(by duration: Duration) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: UInt64(bitPattern: Int64(bitPattern: nanoseconds) &+ duration.wholeNanoseconds))
    }

    /// Signed duration `lhs - rhs`.
    public static func - (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Duration {
        .nanoseconds(Int64(bitPattern: lhs.nanoseconds &- rhs.nanoseconds))
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

extension Duration {
    var wholeNanoseconds: Int64 {
        let parts = components
        return parts.seconds &* 1_000_000_000 &+ parts.attoseconds / 1_000_000_000
    }

    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

/// Monotonic time source plus deadline-based sleeping. Injected everywhere timing matters so tests
/// are deterministic (a test clock only resumes sleepers when it is advanced).
public protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
    /// Suspends until `now() >= deadline`. Throws `CancellationError` if the task is cancelled.
    func sleep(until deadline: MonotonicInstant) async throws
}

/// `CLOCK_UPTIME_RAW` (does not advance while the Mac sleeps).
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    public func sleep(until deadline: MonotonicInstant) async throws {
        let remaining = deadline - now()
        if remaining > .zero {
            try await Task.sleep(for: remaining)
        }
        try Task.checkCancellation()
    }
}

/// A hotkey transition, stamped with a monotonic instant taken in the source's callback.
public struct HotkeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The dictation hotkey went down.
        case down
        /// The dictation hotkey went up.
        case up
        /// Another key was pressed while the hotkey is held (for example Right Option + e).
        case chord
    }

    public let kind: Kind
    public let timestamp: MonotonicInstant

    public init(_ kind: Kind, at timestamp: MonotonicInstant) {
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// A global hold-to-talk hotkey. Implementations deliver events on the main actor.
@MainActor
public protocol HotkeySource: AnyObject {
    var events: AsyncStream<HotkeyEvent> { get }
    func start() throws
    func stop()
}
