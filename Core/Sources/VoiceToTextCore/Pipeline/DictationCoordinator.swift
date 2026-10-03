import Foundation
import Observation
import os

/// What the menu-bar icon shows.
public enum DictationState: Sendable, Equatable {
    /// The engine is not `.ready`; key-downs are ignored and the menu shows the engine status.
    case notReady
    case idle
    /// Key is down and the session is being made; capture has not started yet.
    case starting
    case recording
    case processing
    /// Text was inserted raw because cleanup fell back; shown for `fallbackDisplayDuration`.
    case fallback
    /// The last dictation failed (engine, capture or insert error). Cleared by the next dictation.
    case error
}

/// Failures the coordinator raises itself (engine, capture and insert errors pass through as-is).
public enum DictationError: Error, Sendable, Equatable, LocalizedError {
    /// `finish()` did not return within the deadline; the session was cancelled.
    case transcriptionTimedOut(after: Duration)

    public var errorDescription: String? {
        switch self {
        case .transcriptionTimedOut(let limit):
            "Transcription did not finish within \(Int(limit.components.seconds)) s and was cancelled."
        }
    }
}

/// Hold-to-talk state machine: hotkey → engine session → capture → finish → clean → insert.
///
/// Audio never passes through here: capture feeds the session directly.
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var state: DictationState = .notReady
    public private(set) var engineState: EngineState = .notReady
    public private(set) var lastErrorDescription: String?

    private var engine: any TranscriptionEngine
    private let capture: any AudioCapture
    private let cleaner: any TextCleaner
    private let inserter: any TextInserter
    private let clock: any MonotonicClock
    private let fallbackDisplayDuration: Duration

    @ObservationIgnored private var holdFilter: HoldFilter
    @ObservationIgnored private var session: (any TranscriptionSession)?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var trace: DictationLatencyTrace?
    @ObservationIgnored private var captureStartedAt: MonotonicInstant?
    /// Bumped per `finish()` and on its timeout; a late `finish()` result for an older one is dropped.
    @ObservationIgnored private var processingGeneration = 0
    /// Bumped by `setEngine(_:)`; an `observeEngineStates()` loop for an older engine stops.
    @ObservationIgnored private var engineGeneration = 0

    private static let engineLogger = Logger(subsystem: Latency.subsystem, category: "engine")

    /// The in-flight start / finish / cancel work. Internal so tests can await it.
    @ObservationIgnored var activityTask: Task<Void, Never>?
    @ObservationIgnored var watchdogTask: Task<Void, Never>?
    @ObservationIgnored var fallbackTask: Task<Void, Never>?
    @ObservationIgnored var sttTimeoutTask: Task<Void, Never>?

    /// How long `finish()` may take before the session is cancelled: `max(10 s, audio × 0.5 + 5 s)`.
    /// Deliberately generous (on-device STT measures ~0.2 s for 10 s of audio), so it only fires on
    /// a real hang, e.g. a wedged analyzer; 90 s of audio (the maximum hold) gets 50 s.
    /// Batch (cloud) engines upload in `finish()`, so they get `max(30 s, audio × 0.5 + 15 s)`.
    static func sttDeadline(forAudio audio: Duration, isStreaming: Bool = true) -> Duration {
        isStreaming
            ? max(.seconds(10), audio * 0.5 + .seconds(5))
            : max(.seconds(30), audio * 0.5 + .seconds(15))
    }

    public init(
        engine: any TranscriptionEngine,
        capture: any AudioCapture,
        cleaner: any TextCleaner,
        inserter: any TextInserter,
        clock: any MonotonicClock = SystemMonotonicClock(),
        holdThreshold: Duration = HoldFilter.defaultMinimumHold,
        maximumHold: Duration = HoldFilter.defaultMaximumHold,
        fallbackDisplayDuration: Duration = .milliseconds(1500)
    ) {
        self.engine = engine
        self.capture = capture
        self.cleaner = cleaner
        self.inserter = inserter
        self.clock = clock
        self.fallbackDisplayDuration = fallbackDisplayDuration
        holdFilter = HoldFilter(minimumHold: holdThreshold, maximumHold: maximumHold)
    }

    // MARK: Engine state

    public var engineDescriptor: EngineDescriptor { engine.descriptor }

    /// Swaps the engine. The new engine starts out `.notReady` until its `states` say otherwise
    /// (run `observeEngineStates()` again). A dictation already in flight finishes on its session.
    public func setEngine(_ newEngine: any TranscriptionEngine) {
        engine = newEngine
        engineGeneration &+= 1
        updateEngineState(.notReady)
    }

    /// Follows the current engine's `states` until the stream finishes or the engine is swapped.
    public func observeEngineStates() async {
        let generation = engineGeneration
        for await engineState in engine.states {
            guard generation == engineGeneration else { return }
            updateEngineState(engineState)
        }
    }

    public func updateEngineState(_ newState: EngineState) {
        if newState.kind != engineState.kind {
            Self.engineLogger.notice(
                "engine \(self.engine.descriptor.id.rawValue, privacy: .public) state=\(newState.kind, privacy: .public)"
            )
        }
        engineState = newState
        switch state {
        case .idle, .notReady:
            state = restingState
        case .error, .fallback:
            if !newState.isReady {
                fallbackTask?.cancel()
                fallbackTask = nil
                state = .notReady
            }
        case .starting, .recording, .processing:
            break  // the current dictation finishes; the resting state is recomputed afterwards
        }
    }

    // MARK: Hotkey input

    /// Feeds every event of `source` into `handle(_:)` until its stream finishes.
    public func consume(_ source: any HotkeySource) async {
        for await event in source.events {
            handle(event)
        }
    }

    /// Never blocks: slow work runs in `activityTask`, so a key-up during `.starting` is seen.
    public func handle(_ event: HotkeyEvent) {
        switch event.kind {
        case .down: keyDown(at: event.timestamp)
        case .up: keyUp(at: event.timestamp)
        case .chord: chord(at: event.timestamp)
        }
    }

    private func keyDown(at instant: MonotonicInstant) {
        guard engineState.isReady else { return }
        switch state {
        case .idle, .fallback, .error: break
        case .notReady, .starting, .recording, .processing: return
        }
        guard holdFilter.keyDown(at: instant) == .started else { return }
        fallbackTask?.cancel()
        fallbackTask = nil
        cancelRequested = false
        lastErrorDescription = nil
        trace = DictationLatencyTrace(keyDown: instant)
        state = .starting
        activityTask = Task { await self.startDictation() }
    }

    private func keyUp(at instant: MonotonicInstant) {
        let decision = holdFilter.keyUp(at: instant)
        switch (state, decision) {
        case (_, .ignored):
            break
        case (.starting, _):
            cancelRequested = true
        case (.recording, .accepted):
            beginProcessing(releasedAt: instant)
        case (.recording, _):
            cancelRecording()
        default:
            break
        }
    }

    private func chord(at instant: MonotonicInstant) {
        guard holdFilter.chord(at: instant) == .chordCancel else { return }
        switch state {
        case .starting: cancelRequested = true
        case .recording: cancelRecording()
        default: break
        }
    }

    // MARK: Pipeline

    private func startDictation() async {
        let newSession: any TranscriptionSession
        do {
            newSession = try await engine.makeSession()
        } catch {
            fail(error, stage: "session")
            return
        }
        if cancelRequested {
            cancelRequested = false
            trace?.abandon()
            trace = nil
            await newSession.cancel()
            state = restingState
            return
        }
        do {
            try capture.start(sink: newSession)
        } catch {
            await newSession.cancel()
            fail(error, stage: "capture")
            return
        }
        session = newSession
        let captureStart = clock.now()
        captureStartedAt = captureStart
        trace?.captureDidStart(at: captureStart)
        state = .recording
        armWatchdog()
    }

    private func armWatchdog() {
        watchdogTask?.cancel()
        guard let deadline = holdFilter.deadline else { return }
        watchdogTask = Task { [clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self.watchdogFired()
        }
    }

    private func watchdogFired() {
        guard state == .recording else { return }
        let now = clock.now()
        if case .forceEnd = holdFilter.checkTimeout(at: now) {
            beginProcessing(releasedAt: now)
        } else {
            armWatchdog()
        }
    }

    private func beginProcessing(releasedAt instant: MonotonicInstant) {
        watchdogTask?.cancel()
        watchdogTask = nil
        capture.stop()
        guard let finishing = session else {
            state = restingState
            return
        }
        session = nil
        trace?.released(at: instant)
        state = .processing

        let audio = captureStartedAt.map { instant - $0 } ?? .zero
        captureStartedAt = nil
        let limit = Self.sttDeadline(forAudio: audio, isStreaming: engine.descriptor.isStreaming)
        let deadline = clock.now().advanced(by: limit)
        processingGeneration &+= 1
        let generation = processingGeneration
        sttTimeoutTask?.cancel()
        sttTimeoutTask = Task { [clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self.sttTimedOut(finishing, generation: generation, limit: limit)
        }
        activityTask = Task { await self.process(finishing, generation: generation) }
    }

    private func process(_ finishing: any TranscriptionSession, generation: Int) async {
        trace?.sttDidStart(at: clock.now())
        let raw: String
        do {
            raw = try await finishing.finish()
        } catch {
            guard generation == processingGeneration else { return }  // timed out; already failed
            endSttTimeout()
            fail(error, stage: "stt")
            return
        }
        guard generation == processingGeneration else { return }
        endSttTimeout()
        trace?.sttDidEnd(at: clock.now())

        let outcome = await cleaner.clean(raw)
        trace?.cleanupDidEnd(at: clock.now())

        let isEmpty = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isEmpty {
            do {
                try await inserter.insert(outcome.text)
            } catch {
                fail(error, stage: "insert")
                return
            }
        }
        trace?.pasteDidEnd(at: clock.now())
        if let summary = trace?.summary(outcome: isEmpty ? "empty" : Self.label(outcome.source)) {
            Latency.log(summary)
        }
        trace = nil

        if case .raw = outcome.source {
            showFallback()
        } else {
            state = restingState
        }
    }

    private func endSttTimeout() {
        sttTimeoutTask?.cancel()
        sttTimeoutTask = nil
    }

    /// `finish()` hung: cancel the session and fail, so the next key-down starts a new dictation.
    private func sttTimedOut(_ stuck: any TranscriptionSession, generation: Int, limit: Duration) {
        guard generation == processingGeneration, state == .processing else { return }
        processingGeneration &+= 1  // drop whatever the stuck finish() eventually returns
        sttTimeoutTask = nil
        let stuckWork = activityTask
        activityTask = Task {
            await stuck.cancel()
            await stuckWork?.value
        }
        fail(DictationError.transcriptionTimedOut(after: limit), stage: "stt")
    }

    private func cancelRecording() {
        watchdogTask?.cancel()
        watchdogTask = nil
        capture.stop()
        trace?.abandon()
        trace = nil
        let cancelled = session
        session = nil
        state = restingState
        if let cancelled {
            activityTask = Task { await cancelled.cancel() }
        }
    }

    private func showFallback() {
        state = .fallback
        let deadline = clock.now().advanced(by: fallbackDisplayDuration)
        fallbackTask = Task { [clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            if self.state == .fallback {
                self.state = self.restingState
            }
        }
    }

    private func fail(_ error: any Error, stage: String) {
        watchdogTask?.cancel()
        watchdogTask = nil
        if let orphan = session {
            capture.stop()
            session = nil
            activityTask = Task { await orphan.cancel() }
        }
        trace?.abandon()
        trace = nil
        Latency.logFailure(stage: stage)
        lastErrorDescription = "\(stage): \(error.localizedDescription)"
        state = .error
    }

    private var restingState: DictationState {
        engineState.isReady ? .idle : .notReady
    }

    private static func label(_ source: CleanupOutcome.Source) -> String {
        switch source {
        case .passthrough: "passthrough"
        case .cleaned: "cleaned"
        case .raw: "raw"
        }
    }

    // MARK: Testing support

    /// Awaits the in-flight start / finish / cancel work, including work it chains.
    func settle() async {
        while let task = activityTask {
            await task.value
            if activityTask == task {
                activityTask = nil
            }
        }
    }
}
