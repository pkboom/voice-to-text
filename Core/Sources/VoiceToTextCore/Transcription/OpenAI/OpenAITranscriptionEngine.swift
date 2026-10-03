import AVFoundation
import Foundation

public enum OpenAITranscriptionError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey
    case cannotCreateAudioFormat
    case invalidResponse
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No OpenAI API key. Choose “OpenAI API Key…” in the menu to add one."
        case .cannotCreateAudioFormat:
            "Could not create the 16 kHz audio format for OpenAI."
        case .invalidResponse:
            "OpenAI returned a response that is not a transcript."
        case .http(let status, let message):
            "OpenAI returned HTTP \(status): \(message)"
        }
    }
}

extension EngineID {
    public static let openAIMini = EngineID("openai-mini")
}

extension EngineDescriptor {
    /// OpenAI `gpt-4o-mini-transcribe` (cloud, batch: audio is uploaded on key-up).
    public static let openAIMini = EngineDescriptor(id: .openAIMini, displayName: "OpenAI gpt-4o-mini-transcribe (cloud)", isStreaming: false)
}

/// Cloud transcription with OpenAI's `POST /v1/audio/transcriptions`.
///
/// - `prepare()` only checks that an API key exists (no network), then publishes `.ready`.
/// - A session resamples chunks to 16 kHz mono Int16 in memory; `finish()` wraps them in a WAV,
///   uploads it, and returns the transcript. Nothing is written to disk.
/// - The key is read through `apiKey` on every `prepare()` and `finish()`, so a key saved or
///   removed in the menu takes effect without rebuilding the engine.
public actor OpenAITranscriptionEngine: TranscriptionEngine {
    public typealias APIKeyProvider = @Sendable () -> String?
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let sampleRate: Double = 16_000

    nonisolated public let descriptor: EngineDescriptor
    nonisolated public let model: String
    nonisolated private let language: String?
    nonisolated private let apiKey: APIKeyProvider
    nonisolated private let transport: Transport
    nonisolated private let broadcaster = EngineStateBroadcaster()

    public init(
        model: String = "gpt-4o-mini-transcribe",
        language: String? = "en",
        descriptor: EngineDescriptor = .openAIMini,
        apiKey: @escaping APIKeyProvider,
        transport: @escaping Transport = OpenAITranscriptionEngine.urlSessionTransport
    ) {
        self.model = model
        self.language = language
        self.descriptor = descriptor
        self.apiKey = apiKey
        self.transport = transport
    }

    public static let urlSessionTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    nonisolated public var states: AsyncStream<EngineState> { broadcaster.stream() }

    public func prepare() async {
        guard Self.nonEmpty(apiKey()) != nil else {
            broadcaster.publish(.failed(OpenAITranscriptionError.missingAPIKey))
            return
        }
        broadcaster.publish(.ready)
    }

    public func makeSession() async throws -> any TranscriptionSession {
        guard Self.nonEmpty(apiKey()) != nil else { throw OpenAITranscriptionError.missingAPIKey }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true) else {
            throw OpenAITranscriptionError.cannotCreateAudioFormat
        }
        let request = RequestTemplate(model: model, language: language, apiKey: apiKey, transport: transport)
        return OpenAITranscriptionSession(format: format, request: request)
    }

    public func unload() async {
        broadcaster.publish(.notReady)
    }

    static func nonEmpty(_ key: String?) -> String? {
        guard let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: Request

    struct RequestTemplate: Sendable {
        let model: String
        let language: String?
        let apiKey: APIKeyProvider
        let transport: Transport

        func transcribe(wav: Data) async throws -> String {
            guard let key = OpenAITranscriptionEngine.nonEmpty(apiKey()) else { throw OpenAITranscriptionError.missingAPIKey }
            var fields = [("model", model), ("response_format", "json")]
            if let language { fields.append(("language", language)) }
            let form = MultipartForm(fields: fields, file: .init(name: "file", filename: "audio.wav", contentType: "audio/wav", data: wav))

            var request = URLRequest(url: OpenAITranscriptionEngine.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = form.body

            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw OpenAITranscriptionError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenAITranscriptionError.http(status: http.statusCode, message: Self.errorMessage(in: data))
            }
            guard let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: data) else {
                throw OpenAITranscriptionError.invalidResponse
            }
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private struct TranscriptResponse: Decodable { let text: String }
        private struct ErrorResponse: Decodable {
            struct Body: Decodable { let message: String }
            let error: Body
        }

        static func errorMessage(in data: Data) -> String {
            if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                return decoded.error.message
            }
            return String(decoding: data.prefix(200), as: UTF8.self)
        }
    }
}

/// One dictation. Chunks arrive on the capture thread via `append`, which only yields into a stored
/// continuation; a single pump task resamples them to 16 kHz mono Int16 and accumulates the PCM.
actor OpenAITranscriptionSession: TranscriptionSession {
    nonisolated private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let pump: Task<Data, any Error>
    private let request: OpenAITranscriptionEngine.RequestTemplate
    private let sampleRate: Int
    private var upload: Task<String, any Error>?
    /// Set by `cancel()`; `finish()` checks it after the drain so a cancelled session never uploads.
    private var isCancelled = false

    init(format: AVAudioFormat, request: OpenAITranscriptionEngine.RequestTemplate) {
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        chunkContinuation = continuation
        self.request = request
        sampleRate = Int(format.sampleRate)
        pump = Task(priority: .userInitiated) {
            let resampler = AudioResampler(outputFormat: format)
            var pcm = Data()
            for await chunk in chunks {
                for buffer in try resampler.convert(chunk) {
                    WAVEncoder.appendSamples(of: buffer, to: &pcm)
                }
            }
            for buffer in try resampler.flush() {
                WAVEncoder.appendSamples(of: buffer, to: &pcm)
            }
            return pcm
        }
    }

    nonisolated func append(_ chunk: AudioChunk) {
        chunkContinuation.yield(chunk)
    }

    func finish() async throws -> String {
        chunkContinuation.finish()
        let pcm = try await pump.value
        if isCancelled { throw CancellationError() }
        guard !pcm.isEmpty else { return "" }
        let wav = WAVEncoder.wav(pcm16Mono: pcm, sampleRate: sampleRate)
        let task = Task { [request] in try await request.transcribe(wav: wav) }
        upload = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() async {
        isCancelled = true
        chunkContinuation.finish()
        pump.cancel()
        upload?.cancel()
    }
}

/// Builds a 16-bit PCM mono WAV in memory.
enum WAVEncoder {
    /// Appends the buffer's Int16 samples (little-endian) to `pcm`. Expects mono interleaved Int16.
    static func appendSamples(of buffer: AVAudioPCMBuffer, to pcm: inout Data) {
        guard let channel = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return }
        pcm.append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func wav(pcm16Mono pcm: Data, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        var data = Data(capacity: 44 + pcm.count)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))  // PCM
        data.appendLE(UInt16(channels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(UInt16(channels * bitsPerSample / 8))
        data.appendLE(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// A `multipart/form-data` body with text fields and one file.
struct MultipartForm {
    struct File {
        let name: String
        let filename: String
        let contentType: String
        let data: Data
    }

    let boundary: String
    let body: Data

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(fields: [(String, String)], file: File, boundary: String = "vtt-\(UUID().uuidString)") {
        self.boundary = boundary
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.contentType)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        self.body = body
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
