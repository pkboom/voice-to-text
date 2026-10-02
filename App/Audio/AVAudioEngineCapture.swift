import AVFoundation
import os
import VoiceToTextCore

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No audio input device is available."
        }
    }
}

/// Microphone capture with `AVAudioEngine`.
///
/// - Per session: installs a tap in the input bus's current format (`format: nil`); `stop()` removes it.
/// - Every `AudioChunk` carries the format it was captured in (it can change mid-run).
/// - On `AVAudioEngineConfigurationChange` (device switch, AirPods connect) the engine is reset
///   and re-prepared, and the tap is reinstalled if a session is active (or the mic is kept warm).
/// - `keepWarm`: between sessions the engine keeps running with a discarding tap, so the next
///   `start(sink:)` only swaps the tap (no cold start). Off by default; the mic indicator stays on.
/// - The tap block is built by a `nonisolated` factory: it runs on AVAudioEngine's internal tap
///   thread and must never touch MainActor state (this target defaults to MainActor isolation).
final class AVAudioEngineCapture: AudioCapture {
    private static let logger = Logger(subsystem: Latency.subsystem, category: "capture")
    /// A hint only; AVAudioEngine may deliver other sizes (~21 ms at 48 kHz).
    private static let tapBufferFrames: AVAudioFrameCount = 1024

    private let engine = AVAudioEngine()
    private var sink: (any AudioSink)?
    private var configurationObserver: (any NSObjectProtocol)?

    /// Keep the engine running between sessions (see the type comment).
    var keepWarm = false {
        didSet {
            guard keepWarm != oldValue, sink == nil else { return }
            if keepWarm {
                warmUp()
            } else {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
    }

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    isolated deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start(sink: any AudioSink) throws {
        engine.inputNode.removeTap(onBus: 0)  // a previous session's tap, or the warm discard tap
        self.sink = sink
        do {
            try installTapAndStart(sink: sink)
        } catch {
            self.sink = nil
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        sink = nil
        if keepWarm {
            warmUp()
        } else {
            engine.stop()
        }
    }

    /// Runs the engine with a tap that discards audio.
    private func warmUp() {
        do {
            try installTapAndStart(sink: nil)
        } catch {
            Self.logger.error("keep mic warm: start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `sink == nil` installs a discarding tap (warm mic).
    private func installTapAndStart(sink: (any AudioSink)?) throws {
        let input = engine.inputNode
        let deviceFormat = input.outputFormat(forBus: 0)  // only to detect a missing input device
        guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        let block = sink.map(Self.makeTapBlock(sink:)) ?? Self.discardTapBlock()
        // `format: nil` taps in the bus's own format; each chunk carries its buffer's format.
        input.installTap(onBus: 0, bufferSize: Self.tapBufferFrames, format: nil, block: block)
        engine.prepare()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)  // don't leave the tap block (and its sink) retained
                throw error
            }
        }
    }

    private func handleConfigurationChange() {
        // The engine has stopped itself. When idle, the next start() re-reads the format.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        guard let sink else {
            if keepWarm { warmUp() }
            return
        }
        do {
            try installTapAndStart(sink: sink)
            Self.logger.notice("audio configuration changed; tap reinstalled")
        } catch {
            Self.logger.error("audio configuration changed; restart failed: \(error.localizedDescription, privacy: .public)")
            self.sink = nil
        }
    }

    /// Runs on AVAudioEngine's tap thread. Copies the buffer (AVAudioEngine may reuse tap buffers)
    /// and hands the copy to the sink synchronously; no actor hop per chunk.
    nonisolated static func makeTapBlock(sink: any AudioSink) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let copy = copy(buffer) else { return }
            sink.append(AudioChunk(buffer: copy, format: copy.format))
        }
    }

    nonisolated static func discardTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { _, _ in }
    }

    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
