import AVFoundation
import Synchronization
@testable import VoiceToTextCore

struct MockError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

extension EngineDescriptor {
    static let mock = EngineDescriptor(id: EngineID("mock"), displayName: "Mock", isStreaming: false)
}

/// Suspends waiters until `open()` is called (then lets everyone through, now and later).
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

// MARK: Transcription

final class MockSession: TranscriptionSession {
    struct Stats {
        var chunks = 0
        var frames: AVAudioFrameCount = 0
        var finishCalls = 0
        var cancelCalls = 0
    }

    let analyzerID: Int
    private let transcript: String
    private let finishError: MockError?
    private let finishGate: Gate?
    private let finishHangsUntilCancelled: Bool
    private let cancelled = Gate()
    private let state = Mutex(Stats())

    init(analyzerID: Int, transcript: String, finishError: MockError?, finishGate: Gate?, finishHangsUntilCancelled: Bool = false) {
        self.analyzerID = analyzerID
        self.transcript = transcript
        self.finishError = finishError
        self.finishGate = finishGate
        self.finishHangsUntilCancelled = finishHangsUntilCancelled
    }

    var stats: Stats { state.withLock { $0 } }

    func append(_ chunk: AudioChunk) {
        state.withLock {
            $0.chunks += 1
            $0.frames += chunk.buffer.frameLength
        }
    }

    func finish() async throws -> String {
        state.withLock { $0.finishCalls += 1 }
        if finishHangsUntilCancelled {
            await cancelled.wait()
            throw CancellationError()
        }
        if let finishGate { await finishGate.wait() }
        if let finishError { throw finishError }
        return transcript
    }

    func cancel() async {
        state.withLock { $0.cancelCalls += 1 }
        cancelled.open()
    }
}

/// Models the `TranscriptionEngine` contract, including the "await in-flight next-analyzer prep,
/// never build twice" rule that the real engine must follow.
actor MockTranscriptionEngine: TranscriptionEngine {
    nonisolated let descriptor: EngineDescriptor
    nonisolated let states: AsyncStream<EngineState>
    private let statesContinuation: AsyncStream<EngineState>.Continuation

    private let transcript: String
    private let finishError: MockError?
    private let makeSessionError: MockError?
    private let makeSessionGate: Gate?
    private let finishGate: Gate?
    private let finishHangsUntilCancelled: Bool
    private let preparesNextAnalyzer: Bool
    private let retainsSessions: Bool
    private var backgroundPrepGate: Gate?

    private var preparedAnalyzer: Int?
    private var prepTask: Task<Int, Never>?

    private(set) var analyzerBuilds = 0
    /// Builds done inside `makeSession` because nothing was prepared (should stay 0 when prepared).
    private(set) var inlineBuilds = 0
    /// `makeSession` calls currently suspended on an in-flight prep.
    private(set) var waitersForPrep = 0
    private(set) var sessionsMade = 0
    private(set) var unloadCalls = 0
    private(set) weak var lastSession: MockSession?
    /// Strong references for inspection (empty when `retainsSessions` is false).
    private(set) var sessions: [MockSession] = []

    init(
        descriptor: EngineDescriptor = .mock,
        transcript: String = "hello world",
        finishError: MockError? = nil,
        makeSessionError: MockError? = nil,
        makeSessionGate: Gate? = nil,
        finishGate: Gate? = nil,
        finishHangsUntilCancelled: Bool = false,
        preparesNextAnalyzer: Bool = false,
        retainsSessions: Bool = true
    ) {
        self.descriptor = descriptor
        self.transcript = transcript
        self.finishError = finishError
        self.makeSessionError = makeSessionError
        self.makeSessionGate = makeSessionGate
        self.finishGate = finishGate
        self.finishHangsUntilCancelled = finishHangsUntilCancelled
        self.preparesNextAnalyzer = preparesNextAnalyzer
        self.retainsSessions = retainsSessions
        (states, statesContinuation) = AsyncStream.makeStream()
    }

    func setBackgroundPrepGate(_ gate: Gate?) {
        backgroundPrepGate = gate
    }

    nonisolated func publish(_ state: EngineState) {
        statesContinuation.yield(state)
    }

    nonisolated func finishStates() {
        statesContinuation.finish()
    }

    func prepare() async {
        if preparedAnalyzer == nil, prepTask == nil {
            preparedAnalyzer = build()
        }
        statesContinuation.yield(.ready)
    }

    func makeSession() async throws -> any TranscriptionSession {
        if let makeSessionGate { await makeSessionGate.wait() }
        if let makeSessionError { throw makeSessionError }

        let analyzer: Int
        if let inFlight = prepTask {
            waitersForPrep += 1
            analyzer = await inFlight.value
            waitersForPrep -= 1
            prepTask = nil
        } else if let prepared = preparedAnalyzer {
            analyzer = prepared
        } else {
            inlineBuilds += 1
            analyzer = build()
        }
        preparedAnalyzer = nil
        sessionsMade += 1

        let session = MockSession(
            analyzerID: analyzer, transcript: transcript, finishError: finishError, finishGate: finishGate,
            finishHangsUntilCancelled: finishHangsUntilCancelled
        )
        lastSession = session
        if retainsSessions { sessions.append(session) }
        if preparesNextAnalyzer {
            let gate = backgroundPrepGate
            prepTask = Task {
                await gate?.wait()
                return self.build()
            }
        }
        return session
    }

    func unload() async {
        unloadCalls += 1
        preparedAnalyzer = nil
        statesContinuation.yield(.notReady)
    }

    private func build() -> Int {
        analyzerBuilds += 1
        return analyzerBuilds
    }
}

// MARK: Capture / cleanup / output / hotkey

@MainActor
final class MockAudioCapture: AudioCapture {
    private(set) var sink: (any AudioSink)?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    var startError: MockError?

    func start(sink: any AudioSink) throws {
        startCalls += 1
        if let startError { throw startError }
        self.sink = sink
    }

    func stop() {
        stopCalls += 1
        sink = nil
    }

    /// Simulates the tap thread: hands the chunk straight to the sink.
    func emit(_ chunk: AudioChunk) {
        sink?.append(chunk)
    }
}

final class MockCleaner: TextCleaner {
    private let received = Mutex<[String]>([])
    private let transform: @Sendable (String) -> CleanupOutcome

    init(transform: @escaping @Sendable (String) -> CleanupOutcome = { CleanupOutcome(text: $0.uppercased(), source: .cleaned) }) {
        self.transform = transform
    }

    var inputs: [String] { received.withLock { $0 } }

    func clean(_ raw: String) async -> CleanupOutcome {
        received.withLock { $0.append(raw) }
        return transform(raw)
    }
}

@MainActor
final class MockInserter: TextInserter {
    private(set) var inserted: [String] = []
    var error: MockError?

    func insert(_ text: String) async throws {
        if let error { throw error }
        inserted.append(text)
    }
}

@MainActor
final class MockHotkeySource: HotkeySource {
    let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    private(set) var isRunning = false

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() throws { isRunning = true }
    func stop() { isRunning = false }

    func send(_ event: HotkeyEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
}

// MARK: Audio helpers

enum TestAudio {
    static func format(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    }

    /// A 440 Hz sine buffer; `startFrame` keeps phase continuous across consecutive chunks.
    static func sine(format: AVAudioFormat, frames: AVAudioFrameCount, startFrame: Int = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let step = 2 * Double.pi * 440 / format.sampleRate
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(0.5 * sin(step * Double(startFrame + frame)))
            }
        }
        return buffer
    }

    static func chunk(frames: AVAudioFrameCount = 1_600) -> AudioChunk {
        AudioChunk(buffer: sine(format: format(sampleRate: 16_000, channels: 1), frames: frames))
    }
}
