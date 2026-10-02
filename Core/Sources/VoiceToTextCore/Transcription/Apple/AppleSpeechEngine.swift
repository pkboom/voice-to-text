import AVFoundation
import Foundation
import Speech
import Synchronization

public enum AppleSpeechEngineError: Error, Sendable, LocalizedError {
    case localeUnsupported(String)
    case transcriberUnavailable
    case assetsUnsupported(String)
    case assetsNotInstalled(String)
    case noCompatibleAudioFormat

    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale):
            "Apple Speech does not support the locale \(locale) on this Mac."
        case .transcriberUnavailable:
            "Apple SpeechTranscriber is not available on this device."
        case .assetsUnsupported(let locale):
            "The on-device speech model for \(locale) is not supported on this Mac."
        case .assetsNotInstalled(let locale):
            "The on-device speech model for \(locale) is not installed. Connect to the network so macOS can download it (System Settings > General > Language & Region > Speech), then choose Retry in the menu."
        case .noCompatibleAudioFormat:
            "SpeechAnalyzer reported no compatible audio format."
        }
    }
}

/// On-device transcription with `SpeechAnalyzer`.
///
/// - `prepare()` resolves the locale, installs the speech assets (publishing `.downloading(p)`),
///   picks the analyzer's audio format and pre-prepares the **next analyzer**, then publishes `.ready`.
/// - `makeSession()` takes that analyzer (awaiting it if its prep is still in flight; exactly one
///   build per session), starts its input sequence before returning, then prepares the following
///   analyzer in the background.
/// - Audio stays in memory: chunks → `AudioResampler` → `AnalyzerInput`.
public actor AppleSpeechEngine: TranscriptionEngine {
    /// Which Apple speech module backs the analyzer (the Step 3 bake-off runs all of them).
    public enum Variant: String, Sendable, CaseIterable {
        /// `SpeechTranscriber`, no reporting options.
        case speechTranscriber
        /// `SpeechTranscriber` with `.fastResults`.
        case speechTranscriberFastResults
        /// `DictationTranscriber` with the `.shortDictation` preset.
        case dictationShort
    }

    public static let defaultVariant: Variant = .speechTranscriber

    nonisolated public let descriptor: EngineDescriptor
    nonisolated public let variant: Variant
    nonisolated private let requestedLocale: Locale
    nonisolated private let broadcaster = EngineStateBroadcaster()

    private var setupTask: Task<Setup, any Error>?
    /// The next analyzer: in flight or already prepared. Taken (set to nil) by `makeSession`.
    private var nextAnalyzer: Task<PreparedAnalyzer, any Error>?
    /// Analyzer builds so far (one per session, plus the one `prepare()` makes).
    public private(set) var analyzerBuilds = 0

    public init(
        variant: Variant = AppleSpeechEngine.defaultVariant,
        locale: Locale = Locale(identifier: "en-US"),
        descriptor: EngineDescriptor = .apple
    ) {
        self.variant = variant
        self.requestedLocale = locale
        self.descriptor = descriptor
    }

    nonisolated public var states: AsyncStream<EngineState> { broadcaster.stream() }

    public func prepare() async {
        do {
            let setup = try await ensureSetup()
            let prep = nextAnalyzer ?? startAnalyzerBuild(setup)
            nextAnalyzer = prep
            do {
                _ = try await prep.value
            } catch {
                if nextAnalyzer == prep { nextAnalyzer = nil }  // a failed prep is not reused; retry rebuilds
                throw error
            }
            broadcaster.publish(.ready)
        } catch {
            broadcaster.publish(.failed(error))
        }
    }

    public func makeSession() async throws -> any TranscriptionSession {
        let setup = try await ensureSetup()
        // Take the in-flight (or finished) prep, or build exactly one analyzer if none exists.
        let prep = nextAnalyzer ?? startAnalyzerBuild(setup)
        nextAnalyzer = nil
        let prepared = try await prep.value

        let session = try await AppleSpeechSession.start(prepared, format: setup.format)
        if nextAnalyzer == nil {
            nextAnalyzer = startAnalyzerBuild(setup)
        }
        return session
    }

    public func unload() async {
        nextAnalyzer?.cancel()
        nextAnalyzer = nil
        setupTask?.cancel()
        setupTask = nil
        broadcaster.publish(.notReady)
    }

    // MARK: Setup

    private struct Setup: Sendable {
        let locale: Locale
        let format: AVAudioFormat
        /// The module used for the asset check; the first analyzer reuses it.
        let firstModule: TranscriberModule
    }

    private func ensureSetup() async throws -> Setup {
        let task = setupTask ?? Task { [variant, requestedLocale, broadcaster] in
            try await Self.runSetup(variant: variant, locale: requestedLocale, broadcaster: broadcaster)
        }
        setupTask = task
        do {
            return try await task.value
        } catch {
            if setupTask == task { setupTask = nil }  // let a later prepare() retry
            throw error
        }
    }

    private static func runSetup(variant: Variant, locale requested: Locale, broadcaster: EngineStateBroadcaster) async throws -> Setup {
        let resolved: Locale?
        switch variant {
        case .speechTranscriber, .speechTranscriberFastResults:
            guard SpeechTranscriber.isAvailable else { throw AppleSpeechEngineError.transcriberUnavailable }
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        case .dictationShort:
            resolved = await DictationTranscriber.supportedLocale(equivalentTo: requested)
        }
        guard let locale = resolved else {
            throw AppleSpeechEngineError.localeUnsupported(requested.identifier)
        }

        let module = TranscriberModule(variant: variant, locale: locale)
        try await installAssetsIfNeeded(for: module, locale: locale, broadcaster: broadcaster)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module]) else {
            throw AppleSpeechEngineError.noCompatibleAudioFormat
        }
        return Setup(locale: locale, format: format, firstModule: module)
    }

    private static func installAssetsIfNeeded(for module: TranscriberModule, locale: Locale, broadcaster: EngineStateBroadcaster) async throws {
        switch await AssetInventory.status(forModules: [module.module]) {
        case .installed:
            return
        case .unsupported:
            throw AppleSpeechEngineError.assetsUnsupported(locale.identifier)
        case .supported, .downloading:
            break
        @unknown default:
            break
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) else {
            return  // nothing to install
        }
        broadcaster.publish(.downloading(0))
        let progressTask = Task {
            while !Task.isCancelled {
                broadcaster.publish(.downloading(request.progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw AppleSpeechEngineError.assetsNotInstalled("\(locale.identifier) (\(error.localizedDescription))")
        }
        guard await AssetInventory.status(forModules: [module.module]) == .installed else {
            throw AppleSpeechEngineError.assetsNotInstalled(locale.identifier)
        }
    }

    // MARK: Analyzer prep

    private func startAnalyzerBuild(_ setup: Setup) -> Task<PreparedAnalyzer, any Error> {
        analyzerBuilds += 1
        // The first build reuses the module that passed the asset check.
        let module = analyzerBuilds == 1 ? setup.firstModule : TranscriberModule(variant: variant, locale: setup.locale)
        let format = setup.format
        return Task(priority: .userInitiated) {
            let analyzer = SpeechAnalyzer(
                modules: [module.module],
                options: .init(priority: .userInitiated, modelRetention: .processLifetime)
            )
            try await analyzer.prepareToAnalyze(in: format)
            return PreparedAnalyzer(analyzer: analyzer, module: module)
        }
    }
}

/// A speech module plus a type-erased way to collect its finalized text.
struct TranscriberModule: Sendable {
    let module: any SpeechModule
    /// Iterates the module's results and returns the concatenated finalized text.
    let collectFinalText: @Sendable () async throws -> String

    init(variant: AppleSpeechEngine.Variant, locale: Locale) {
        switch variant {
        case .speechTranscriber, .speechTranscriberFastResults:
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: variant == .speechTranscriberFastResults ? [.fastResults] : [],
                attributeOptions: []
            )
            module = transcriber
            collectFinalText = {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    TranscriptJoiner.append(String(result.text.characters), to: &text)
                }
                return text
            }
        case .dictationShort:
            let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
            module = transcriber
            collectFinalText = {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    TranscriptJoiner.append(String(result.text.characters), to: &text)
                }
                return text
            }
        }
    }
}

enum TranscriptJoiner {
    /// Appends a finalized segment, inserting a space when neither side already has whitespace.
    static func append(_ segment: String, to text: inout String) {
        guard !segment.isEmpty else { return }
        if let last = text.last, !last.isWhitespace, let first = segment.first, !first.isWhitespace {
            text.append(" ")
        }
        text.append(segment)
    }
}

struct PreparedAnalyzer: Sendable {
    let analyzer: SpeechAnalyzer
    let module: TranscriberModule
}

/// One dictation on one analyzer. Chunks arrive on the capture thread via `append`, which only
/// yields into a stored continuation; a single pump task resamples them and feeds the analyzer.
actor AppleSpeechSession: TranscriptionSession {
    private let analyzer: SpeechAnalyzer
    nonisolated private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let pump: Task<Void, any Error>
    private let results: Task<String, any Error>

    private init(
        analyzer: SpeechAnalyzer,
        chunkContinuation: AsyncStream<AudioChunk>.Continuation,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        pump: Task<Void, any Error>,
        results: Task<String, any Error>
    ) {
        self.analyzer = analyzer
        self.chunkContinuation = chunkContinuation
        self.inputContinuation = inputContinuation
        self.pump = pump
        self.results = results
    }

    /// Starts the analyzer's input sequence (so early chunks queue) and the pump.
    static func start(_ prepared: PreparedAnalyzer, format: AVAudioFormat) async throws -> AppleSpeechSession {
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (chunks, chunkContinuation) = AsyncStream<AudioChunk>.makeStream()

        let collect = prepared.module.collectFinalText
        let results = Task(priority: .userInitiated) { try await collect() }
        do {
            try await prepared.analyzer.start(inputSequence: inputs)
        } catch {
            results.cancel()
            throw error
        }

        let pump = Task(priority: .userInitiated) {
            defer { inputContinuation.finish() }
            let resampler = AudioResampler(outputFormat: format)
            for await chunk in chunks {
                // A fresh output buffer per conversion (AudioResampler guarantees no aliasing).
                for buffer in try resampler.convert(chunk) {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
            for buffer in try resampler.flush() {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
            }
        }

        return AppleSpeechSession(
            analyzer: prepared.analyzer,
            chunkContinuation: chunkContinuation,
            inputContinuation: inputContinuation,
            pump: pump,
            results: results
        )
    }

    nonisolated func append(_ chunk: AudioChunk) {
        chunkContinuation.yield(chunk)
    }

    func finish() async throws -> String {
        chunkContinuation.finish()
        do {
            try await pump.value  // drains queued chunks, flushes the resampler, ends the input
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await results.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        chunkContinuation.finish()
        pump.cancel()
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}

/// Publishes `EngineState` to any number of observers; each new stream starts with the current state.
final class EngineStateBroadcaster: Sendable {
    private struct State {
        var current: EngineState = .notReady
        var observers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func stream() -> AsyncStream<EngineState> {
        let (stream, continuation) = AsyncStream<EngineState>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        state.withLock { state in
            continuation.yield(state.current)
            state.observers[id] = continuation
        }
        return stream
    }

    func publish(_ newState: EngineState) {
        state.withLock { state in
            state.current = newState
            for observer in state.observers.values {
                observer.yield(newState)
            }
        }
    }
}
