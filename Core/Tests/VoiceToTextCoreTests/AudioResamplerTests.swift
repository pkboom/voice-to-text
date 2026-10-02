import AVFoundation
import Testing
@testable import VoiceToTextCore

@Suite struct AudioResamplerTests {
    private let target = TestAudio.format(sampleRate: 16_000, channels: 1)

    private func frames(_ buffers: [AVAudioPCMBuffer]) -> Int {
        buffers.reduce(0) { $0 + Int($1.frameLength) }
    }

    /// Feeds `seconds` of audio at `format` in 100 ms chunks.
    private func feed(_ resampler: AudioResampler, format: AVAudioFormat, seconds: Double) throws -> [AVAudioPCMBuffer] {
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
        let chunks = Int((seconds * 10).rounded())
        var output: [AVAudioPCMBuffer] = []
        for index in 0..<chunks {
            let input = TestAudio.sine(format: format, frames: chunkFrames, startFrame: index * Int(chunkFrames))
            output += try resampler.convert(AudioChunk(buffer: input))
        }
        return output
    }

    @Test func converts48kStereoTo16kMonoWithinOnePercent() throws {
        let resampler = AudioResampler(outputFormat: target)
        let source = TestAudio.format(sampleRate: 48_000, channels: 2)
        var output = try feed(resampler, format: source, seconds: 1)
        output += try resampler.flush()

        #expect(output.allSatisfy { $0.format == target })
        #expect(abs(frames(output) - 16_000) <= 160)
        #expect(resampler.converterBuildCount == 1)
        let peak = output.flatMap { buffer in (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) } }.max() ?? 0
        #expect(peak > 0.1, "converted audio should not be silent")
    }

    @Test func flushEmitsTheTail() throws {
        let resampler = AudioResampler(outputFormat: target)
        let source = TestAudio.format(sampleRate: 48_000, channels: 2)
        let beforeFlush = frames(try feed(resampler, format: source, seconds: 1))
        let tail = try resampler.flush()

        #expect(frames(tail) > 0)
        #expect(abs(beforeFlush + frames(tail) - 16_000) <= 160)
        #expect(try resampler.flush().isEmpty, "a second flush has nothing left")
    }

    @Test func everyConversionReturnsADistinctBuffer() throws {
        let resampler = AudioResampler(outputFormat: target)
        let source = TestAudio.format(sampleRate: 48_000, channels: 2)
        let inputs = (0..<10).map { TestAudio.sine(format: source, frames: 4_800, startFrame: $0 * 4_800) }
        var output: [AVAudioPCMBuffer] = []
        for input in inputs {
            output += try resampler.convert(input)
        }
        output += try resampler.flush()

        let ids = Set(output.map(ObjectIdentifier.init))
        #expect(ids.count == output.count)
        #expect(ids.isDisjoint(with: inputs.map(ObjectIdentifier.init)))
    }

    @Test func formatChangeMidSessionFlushesOldTailBeforeRebuild() throws {
        let format48 = TestAudio.format(sampleRate: 48_000, channels: 2)
        let format44 = TestAudio.format(sampleRate: 44_100, channels: 2)
        let firstNew = TestAudio.sine(format: format44, frames: 4_410)

        // Reference numbers from independent resamplers (converters are deterministic).
        let reference48 = AudioResampler(outputFormat: target)
        let old = frames(try feed(reference48, format: format48, seconds: 0.5))
        let oldTail = frames(try reference48.flush())
        let firstNewAlone = frames(try AudioResampler(outputFormat: target).convert(firstNew))

        let resampler = AudioResampler(outputFormat: target)
        let before = frames(try feed(resampler, format: format48, seconds: 0.5))
        #expect(before == old)

        // The call that sees the new format returns the old converter's tail plus the new audio.
        let atChange = frames(try resampler.convert(firstNew))
        #expect(atChange == oldTail + firstNewAlone)
        #expect(resampler.converterBuildCount == 2)

        var rest: [AVAudioPCMBuffer] = []
        for index in 1..<5 {
            rest += try resampler.convert(TestAudio.sine(format: format44, frames: 4_410, startFrame: index * 4_410))
        }
        rest += try resampler.flush()

        let total = before + atChange + frames(rest)
        #expect(abs(total - 16_000) <= 160)
        #expect(resampler.converterBuildCount == 2)
    }
}
