/// Stable identifier of a transcription engine; persisted by `SettingsStore`.
public struct EngineID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let apple = EngineID("apple")
}

public struct EngineDescriptor: Sendable, Hashable, Identifiable {
    public let id: EngineID
    public let displayName: String
    /// `true` if the engine transcribes while audio streams in; batch engines (`false`) accumulate
    /// audio and transcribe in `finish()`.
    public let isStreaming: Bool

    public init(id: EngineID, displayName: String, isStreaming: Bool) {
        self.id = id
        self.displayName = displayName
        self.isStreaming = isStreaming
    }

    /// Apple `SpeechAnalyzer` + `SpeechTranscriber` (on-device). Implemented in `Transcription/Apple`.
    public static let apple = EngineDescriptor(id: .apple, displayName: "Apple Speech (on-device)", isStreaming: true)
}

public enum EngineState: Sendable {
    case notReady
    case downloading(Double)
    case ready
    case failed(any Error)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The case name without its payload (for logs; never contains user content).
    public var kind: String {
        switch self {
        case .notReady: "notReady"
        case .downloading: "downloading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}

/// An on-device speech-to-text engine.
///
/// Contract (every implementation must honour it; the coordinator relies on it):
/// - `states` returns a stream that starts with the current state and then publishes changes.
///   Each access returns a new stream, so several observers may subscribe.
/// - `prepare()` makes the engine ready (assets, model, the first pre-prepared analyzer) and
///   publishes `.ready`, or `.failed` / `.downloading(p)` along the way. Calling it again is cheap.
/// - `makeSession()` returns a session whose input is already running, so chunks appended right
///   away are queued, not lost. If a background prep of the next analyzer is **in flight**,
///   `makeSession()` awaits that prep and takes its result; it must never start a second, duplicate
///   build (exactly one analyzer build per session). After handing a session out, the engine may
///   prepare the following analyzer in the background.
/// - `unload()` releases models; the engine publishes `.notReady` until `prepare()` runs again.
public protocol TranscriptionEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    var states: AsyncStream<EngineState> { get }
    func prepare() async
    func makeSession() async throws -> any TranscriptionSession
    func unload() async
}

/// One dictation. Audio arrives through `append` (from `AudioSink`) directly from the capture
/// thread. Exactly one of `finish()` or `cancel()` is called.
public protocol TranscriptionSession: AudioSink {
    /// Ends input, drains queued audio, and returns the final, trimmed transcript.
    func finish() async throws -> String
    /// Discards the session and everything it buffered.
    func cancel() async
}

/// The engines the app can offer. Descriptors are static data; factories are bound where the
/// concrete engine type is visible (`EngineRegistry.standard` in `EngineRegistry+Standard.swift`,
/// mocks in tests), so this file never references a concrete engine.
public struct EngineRegistry: Sendable {
    public typealias Factory = @Sendable () -> any TranscriptionEngine

    public struct Entry: Sendable {
        public let descriptor: EngineDescriptor
        public let makeEngine: Factory

        public init(descriptor: EngineDescriptor, makeEngine: @escaping Factory) {
            self.descriptor = descriptor
            self.makeEngine = makeEngine
        }
    }

    public let entries: [Entry]

    public init(_ entries: [Entry]) {
        precondition(Set(entries.map(\.descriptor.id)).count == entries.count, "duplicate EngineID in EngineRegistry")
        self.entries = entries
    }

    public var descriptors: [EngineDescriptor] { entries.map(\.descriptor) }

    public func descriptor(for id: EngineID) -> EngineDescriptor? {
        entries.first { $0.descriptor.id == id }?.descriptor
    }

    /// A new engine for `id`, or `nil` if no factory is registered for it.
    public func makeEngine(for id: EngineID) -> (any TranscriptionEngine)? {
        entries.first { $0.descriptor.id == id }?.makeEngine()
    }
}
