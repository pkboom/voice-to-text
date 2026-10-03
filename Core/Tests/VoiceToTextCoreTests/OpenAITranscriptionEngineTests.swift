import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VoiceToTextCore

@Suite struct OpenAITranscriptionEngineTests {
    /// Records requests and answers with a canned response.
    final class FakeTransport: Sendable {
        private let requests = Mutex<[URLRequest]>([])
        let status: Int
        let body: Data

        init(status: Int = 200, json: String = #"{"text":"  hello world \n"}"#) {
            self.status = status
            body = Data(json.utf8)
        }

        var recorded: [URLRequest] { requests.withLock { $0 } }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.withLock { $0.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private func engine(key: String? = "sk-test", transport: FakeTransport) -> OpenAITranscriptionEngine {
        OpenAITranscriptionEngine(model: "gpt-4o-mini-transcribe", apiKey: { key }, transport: transport.send)
    }

    private func firstState(of engine: OpenAITranscriptionEngine) async -> EngineState? {
        for await state in engine.states where state.kind != "notReady" {
            return state
        }
        return nil
    }

    @Test func prepareIsReadyWithAKey() async {
        let engine = engine(transport: FakeTransport())
        await engine.prepare()
        #expect(await firstState(of: engine)?.isReady == true)
    }

    @Test func prepareFailsWithoutAKey() async throws {
        let engine = engine(key: "  ", transport: FakeTransport())
        await engine.prepare()
        let state = await firstState(of: engine)
        guard case .failed(let error) = state else {
            Issue.record("expected .failed, got \(String(describing: state))")
            return
        }
        #expect(error as? OpenAITranscriptionError == .missingAPIKey)
        await #expect(throws: OpenAITranscriptionError.missingAPIKey) { try await engine.makeSession() }
    }

    @Test func finishUploadsAWavAndReturnsTheTrimmedTranscript() async throws {
        let transport = FakeTransport()
        let session = try await engine(transport: transport).makeSession()
        let source = TestAudio.format(sampleRate: 48_000, channels: 2)
        for index in 0..<10 {
            session.append(AudioChunk(buffer: TestAudio.sine(format: source, frames: 4_800, startFrame: index * 4_800)))
        }
        let text = try await session.finish()
        #expect(text == "hello world")

        let request = try #require(transport.recorded.first)
        #expect(transport.recorded.count == 1)
        #expect(request.url == OpenAITranscriptionEngine.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try #require(request.httpBody)
        let text8 = String(decoding: body, as: UTF8.self)
        #expect(text8.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        #expect(text8.contains("filename=\"audio.wav\""))
        let riff = try #require(body.range(of: Data("RIFF".utf8)))
        let header = body[riff.lowerBound..<riff.lowerBound + 44]
        #expect(header.dropFirst(8).prefix(4) == Data("WAVE".utf8))
        let sampleRate = header.dropFirst(24).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: sampleRate) == 16_000)
        let dataSize = Int(UInt32(littleEndian: header.dropFirst(40).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        // 1 s of audio at 16 kHz Int16 mono is ~32 000 bytes.
        #expect(abs(dataSize - 32_000) <= 320)
    }

    @Test func emptyAudioSkipsTheUpload() async throws {
        let transport = FakeTransport()
        let session = try await engine(transport: transport).makeSession()
        #expect(try await session.finish() == "")
        #expect(transport.recorded.isEmpty)
    }

    @Test func httpErrorsSurfaceTheAPIMessage() async throws {
        let transport = FakeTransport(status: 401, json: #"{"error":{"message":"Incorrect API key provided"}}"#)
        let session = try await engine(transport: transport).makeSession()
        session.append(TestAudio.chunk())
        await #expect(throws: OpenAITranscriptionError.http(status: 401, message: "Incorrect API key provided")) {
            try await session.finish()
        }
    }

    @Test func cancelDuringDrainNeverUploads() async throws {
        let transport = FakeTransport()
        let session = try await engine(transport: transport).makeSession()
        session.append(TestAudio.chunk())
        let finishing = Task { try await session.finish() }
        await session.cancel()
        _ = await finishing.result
        #expect(transport.recorded.isEmpty)
    }

    @MainActor @Test func batchEnginesGetALongerSTTDeadline() {
        #expect(DictationCoordinator.sttDeadline(forAudio: .seconds(3), isStreaming: false) == .seconds(30))
        #expect(DictationCoordinator.sttDeadline(forAudio: .seconds(90), isStreaming: false) == .seconds(60))
        #expect(DictationCoordinator.sttDeadline(forAudio: .seconds(3)) == .seconds(10))
    }

    @Test func wavHeaderMatchesThePCMLength() {
        let pcm = Data(repeating: 1, count: 100)
        let wav = WAVEncoder.wav(pcm16Mono: pcm, sampleRate: 16_000)
        #expect(wav.count == 144)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav.suffix(100) == pcm)
    }
}
