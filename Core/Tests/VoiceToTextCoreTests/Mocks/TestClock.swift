import Foundation
import Synchronization
@testable import VoiceToTextCore

/// Deterministic `MonotonicClock`: time only moves on `advance(by:)`, which resumes every sleeper
/// whose deadline has been reached.
final class TestClock: MonotonicClock {
    private struct Sleeper {
        let deadline: MonotonicInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: MonotonicInstant
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    private let state: Mutex<State>

    init(start: MonotonicInstant = MonotonicInstant(nanoseconds: 1_000_000_000_000)) {
        state = Mutex(State(now: start))
    }

    func now() -> MonotonicInstant {
        state.withLock { $0.now }
    }

    var pendingSleepers: Int {
        state.withLock { $0.sleepers.count }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let dueIDs = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.now >= deadline { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
