import AVFoundation

public enum AudioResamplerError: Error, Sendable, Equatable {
    case cannotCreateConverter(from: String, to: String)
    case cannotAllocateBuffer
    case conversionFailed(String)
}

/// Converts captured chunks to the format a session/engine asks for (for example the analyzer's
/// best format, or 16 kHz mono for batch engines).
///
/// - One `AVAudioConverter` per session, built lazily from the first chunk's format.
/// - The format of **every** chunk is compared; on a change the old converter is drained with
///   `.endOfStream` (its tail is emitted first), then a new converter is built.
/// - Every conversion writes into a fresh output buffer, so emitted buffers never alias.
/// - `flush()` drains the current converter with `.endOfStream`.
///
/// Not thread-safe: owned by a single consumer (the session's pump).
public final class AudioResampler {
    public let outputFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    /// Number of converters built so far (observable by tests).
    private(set) var converterBuildCount = 0

    /// Extra output capacity beyond the exact rate ratio, for converter priming and rounding.
    private static let slackFrames: AVAudioFrameCount = 1024

    public init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    public func convert(_ chunk: AudioChunk) throws -> [AVAudioPCMBuffer] {
        try convert(chunk.buffer)
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        var output: [AVAudioPCMBuffer] = []
        if let current = converter, current.inputFormat != buffer.format {
            converter = nil
            output += try run(current, input: nil, endOfStream: true)
        }
        let active = try converter ?? makeConverter(from: buffer.format)
        output += try run(active, input: buffer, endOfStream: false)
        return output
    }

    /// Drains buffered frames at end of input. The next `convert` builds a new converter.
    public func flush() throws -> [AVAudioPCMBuffer] {
        guard let current = converter else { return [] }
        converter = nil
        return try run(current, input: nil, endOfStream: true)
    }

    private func makeConverter(from inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        guard let made = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioResamplerError.cannotCreateConverter(from: "\(inputFormat)", to: "\(outputFormat)")
        }
        if inputFormat.channelCount > outputFormat.channelCount {
            made.downmix = true
        }
        converter = made
        converterBuildCount += 1
        return made
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> [AVAudioPCMBuffer] {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let expected = (Double(input?.frameLength ?? 0) * ratio).rounded(.up)
        let capacity = AVAudioFrameCount(expected) + Self.slackFrames
        let feed = InputFeed(input)
        var output: [AVAudioPCMBuffer] = []

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioResamplerError.cannotAllocateBuffer
            }
            var error: NSError?
            // Each input buffer is handed over exactly once; afterwards the block reports
            // `.noDataNow` (more audio will come) or `.endOfStream` (drain the tail).
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                if let next = feed.take() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if buffer.frameLength > 0 {
                output.append(buffer)
            }
            switch status {
            case .haveData where buffer.frameLength > 0:
                continue  // output buffer filled up; more may be waiting
            case .error:
                throw AudioResamplerError.conversionFailed(error?.localizedDescription ?? "unknown error")
            default:
                return output
            }
        }
    }
}

/// Hands one input buffer to `AVAudioConverter`'s input block. The block is `@Sendable` in the SDK
/// but is invoked synchronously inside `convert(to:error:withInputFrom:)` on the calling thread,
/// so the box is never accessed concurrently.
private final class InputFeed: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer?) {
        pending = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { pending = nil }
        return pending
    }
}
