import AVFoundation
import Foundation
import Testing
import VoiceToTextCore

/// Real `AppleSpeechEngine`, offline, fed a `say` fixture in 100 ms chunks paced at real time.
/// Gate (Step 3): WER ≤ 0.15 on every run and `stt_ms` p50 ≤ 700 over 5 runs.
///
/// No authorization calls here (R12). `prepare()` may trigger the one-time, OS-managed speech
/// asset download on a fresh Mac (needs network once); afterwards the test runs with Wi-Fi off.
/// Set `VTT_STT_VARIANT` to an `AppleSpeechEngine.Variant` raw value to bake off other modules.
@Suite(.serialized) struct AppleSpeechEngineFileTests {
    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    static let runs = 5
    static let chunkDuration: Duration = .milliseconds(100)
    static let maxWER = 0.15
    static let maxP50Milliseconds = 700.0

    @Test(.timeLimit(.minutes(10)))
    func transcribesFixtureWithinLatencyGate() async throws {
        let wavURL = Self.fixtures.appending(path: "hello-10s.wav")
        let reference = try String(contentsOf: Self.fixtures.appending(path: "hello-10s.txt"), encoding: .utf8)
        let chunks = try Self.loadChunks(wavURL)

        let variant = ProcessInfo.processInfo.environment["VTT_STT_VARIANT"]
            .flatMap(AppleSpeechEngine.Variant.init(rawValue:)) ?? AppleSpeechEngine.defaultVariant
        let engine = AppleSpeechEngine(variant: variant)
        await engine.prepare()
        let state = await Self.currentState(of: engine)
        guard state.isReady else {
            if case .failed(let error) = state {
                Issue.record("AppleSpeechEngine.prepare() failed: \(error.localizedDescription) — make sure the en-US on-device speech model can be installed (network needed once), then rerun `make itest`.")
            } else {
                Issue.record("AppleSpeechEngine not ready after prepare(): \(state)")
            }
            return
        }
        #expect(await engine.analyzerBuilds == 1, "prepare() builds exactly the first analyzer")

        var latencies: [Double] = []
        var wers: [Double] = []
        let clock = ContinuousClock()
        for run in 1...Self.runs {
            let session = try await engine.makeSession()
            let start = clock.now
            for (index, chunk) in chunks.enumerated() {
                // A chunk covering [i, i+1) × 100 ms is delivered when that audio has been "spoken".
                try await clock.sleep(until: start + Self.chunkDuration * (index + 1))
                session.append(chunk)
            }
            let finishStart = clock.now
            let text = try await session.finish()
            let elapsed = clock.now - finishStart
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            let wer = Self.wordErrorRate(reference: reference, hypothesis: text)
            latencies.append(ms.rounded())
            wers.append(wer)
            print("run \(run) [\(variant.rawValue)]: stt_ms=\(Int(ms.rounded())) wer=\(String(format: "%.3f", wer)) text=\"\(text)\"")
            #expect(wer <= Self.maxWER, "run \(run): WER \(wer) > \(Self.maxWER); text=\"\(text)\"")
        }
        // Each session takes the pre-prepared analyzer and starts exactly one background build of
        // the next: prepare()'s build + one per session, never a duplicate inline build.
        #expect(await engine.analyzerBuilds == Self.runs + 1)

        let p50 = Self.median(latencies)
        let werMax = wers.max() ?? 1
        print("stt_ms p50=\(Int(p50)) runs=\(Self.runs) values=[\(latencies.map { String(Int($0)) }.joined(separator: ", "))] wer_max=\(String(format: "%.3f", werMax)) variant=\(variant.rawValue)")
        #expect(p50 <= Self.maxP50Milliseconds, "stt_ms p50 \(p50) > \(Self.maxP50Milliseconds)")
    }

    @Test func wordErrorRateNormalizesCaseAndPunctuation() {
        #expect(Self.wordErrorRate(reference: "Hello, world.", hypothesis: "hello world") == 0)
        #expect(Self.wordErrorRate(reference: "a b c d", hypothesis: "a x c") == 0.5)
    }

    // MARK: Helpers

    static func currentState(of engine: AppleSpeechEngine) async -> EngineState {
        for await state in engine.states { return state }
        return .notReady
    }

    /// Reads the fixture into memory and splits it into fresh 100 ms buffers.
    static func loadChunks(_ url: URL) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        let whole = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total))
        try file.read(into: whole)

        let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
        var chunks: [AudioChunk] = []
        var offset: AVAudioFrameCount = 0
        while offset < whole.frameLength {
            let count = min(chunkFrames, whole.frameLength - offset)
            let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            chunk.frameLength = count
            for channel in 0..<Int(format.channelCount) {
                let source = try #require(whole.floatChannelData)[channel] + Int(offset)
                try #require(chunk.floatChannelData)[channel].update(from: source, count: Int(count))
            }
            chunks.append(AudioChunk(buffer: chunk))
            offset += count
        }
        return chunks
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "'" ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    /// Word-level Levenshtein distance divided by the reference length.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var previous = Array(0...hyp.count)
        for (i, refWord) in ref.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hyp.count)
            for (j, hypWord) in hyp.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (refWord == hypWord ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
