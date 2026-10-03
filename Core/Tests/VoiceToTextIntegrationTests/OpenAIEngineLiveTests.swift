import Foundation
import Testing
import VoiceToTextCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let openAILiveAPIKey: String? = {
    if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
    guard let env = try? String(contentsOf: repoRoot.appending(path: ".env"), encoding: .utf8) else { return nil }
    for line in env.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == "OPENAI_API_KEY" {
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
    return nil
}()

/// Real `OpenAITranscriptionEngine` against the live API, fed the `say` fixture.
/// Runs only when `OPENAI_API_KEY` is set (environment, or `.env` at the repo root); costs a few
/// tenths of a cent per run. `VTT_OPENAI_MODEL` overrides the model.
@Suite(.serialized, .enabled(if: openAILiveAPIKey != nil, "OPENAI_API_KEY not set"))
struct OpenAIEngineLiveTests {
    @Test(.timeLimit(.minutes(2)))
    func transcribesFixture() async throws {
        let fixtures = AppleSpeechEngineFileTests.fixtures
        let reference = try String(contentsOf: fixtures.appending(path: "hello-10s.txt"), encoding: .utf8)
        let chunks = try AppleSpeechEngineFileTests.loadChunks(fixtures.appending(path: "hello-10s.wav"))

        let key = openAILiveAPIKey
        let model = ProcessInfo.processInfo.environment["VTT_OPENAI_MODEL"] ?? "gpt-4o-mini-transcribe"
        let engine = OpenAITranscriptionEngine(model: model, apiKey: { key })
        await engine.prepare()

        let session = try await engine.makeSession()
        for chunk in chunks {
            session.append(chunk)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let text = try await session.finish()
        let elapsed = clock.now - start
        let wer = AppleSpeechEngineFileTests.wordErrorRate(reference: reference, hypothesis: text)
        print("openai [\(model)]: finish_ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) wer=\(String(format: "%.3f", wer)) text=\"\(text)\"")
        #expect(wer <= AppleSpeechEngineFileTests.maxWER, "WER \(wer); text=\"\(text)\"")
    }
}
