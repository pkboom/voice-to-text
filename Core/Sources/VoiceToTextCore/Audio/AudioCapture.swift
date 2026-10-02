import AVFoundation

/// One captured buffer plus the format it was captured in (the input format can change mid-run,
/// for example when AirPods connect).
///
/// `@unchecked Sendable` under a **single-consumer rule**: the producer hands the buffer off and
/// never touches it again; exactly one consumer (the session's pump) reads it afterwards. Nobody
/// mutates a buffer after it has been wrapped in a chunk.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let format: AVAudioFormat

    public init(buffer: AVAudioPCMBuffer, format: AVAudioFormat? = nil) {
        self.buffer = buffer
        self.format = format ?? buffer.format
    }
}

/// Receives audio directly from the capture thread.
///
/// `append` is called synchronously on the audio tap thread. Implementations must not block and
/// must not hop actors per chunk: yield into a stored continuation instead. Actor conformers
/// declare it `nonisolated`.
public protocol AudioSink: Sendable {
    func append(_ chunk: AudioChunk)
}

/// Microphone capture. `start(sink:)` feeds the sink directly from the capture thread
/// (no MainActor hop per chunk); `stop()` stops feeding and releases the sink.
@MainActor
public protocol AudioCapture: AnyObject {
    func start(sink: any AudioSink) throws
    func stop()
}
