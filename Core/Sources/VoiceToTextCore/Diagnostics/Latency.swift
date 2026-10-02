import Foundation
import os

/// Latency instrumentation: `OSSignposter` intervals per stage plus one `Logger` summary line per
/// dictation. Never logs transcript text.
public enum Latency {
    public static let subsystem = "com.keunbae.VoiceToText"
    public static let category = "latency"

    static let signposter = OSSignposter(subsystem: subsystem, category: category)
    static let logger = Logger(subsystem: subsystem, category: category)

    static func log(_ summary: LatencySummary) {
        logger.notice("\(summary.line, privacy: .public)")
    }

    static func logFailure(stage: String) {
        logger.error("dictation failed stage=\(stage, privacy: .public)")
    }
}

/// The per-dictation summary parsed by `scripts/latency-report.sh`.
public struct LatencySummary: Sendable, Equatable {
    /// Key release (or watchdog force-end) → Cmd+V posted. The AC13 endpoint.
    public var totalMs: Int
    public var sttMs: Int
    public var cleanMs: Int
    public var pasteMs: Int
    /// Key-down → capture running (includes `makeSession`).
    public var captureStartMs: Int
    public var audioSeconds: Double
    public var outcome: String

    public init(totalMs: Int, sttMs: Int, cleanMs: Int, pasteMs: Int, captureStartMs: Int, audioSeconds: Double, outcome: String) {
        self.totalMs = totalMs
        self.sttMs = sttMs
        self.cleanMs = cleanMs
        self.pasteMs = pasteMs
        self.captureStartMs = captureStartMs
        self.audioSeconds = audioSeconds
        self.outcome = outcome
    }

    public var line: String {
        "total_ms=\(totalMs) stt_ms=\(sttMs) clean_ms=\(cleanMs) paste_ms=\(pasteMs) "
            + "capture_start_ms=\(captureStartMs) audio_s=\(String(format: "%.2f", audioSeconds)) outcome=\(outcome)"
    }
}

/// Marks and signpost intervals for one dictation. Owned by the coordinator (main actor).
struct DictationLatencyTrace {
    private let signposter = Latency.signposter
    private let id: OSSignpostID
    private let keyDown: MonotonicInstant
    private var captureStarted: MonotonicInstant?
    private var released: MonotonicInstant?
    private var sttStarted: MonotonicInstant?
    private var sttEnded: MonotonicInstant?
    private var cleanEnded: MonotonicInstant?
    private var pasteEnded: MonotonicInstant?

    private var captureInterval: OSSignpostIntervalState?
    private var releaseInterval: OSSignpostIntervalState?
    private var sttInterval: OSSignpostIntervalState?
    private var cleanInterval: OSSignpostIntervalState?
    private var pasteInterval: OSSignpostIntervalState?

    init(keyDown: MonotonicInstant) {
        self.keyDown = keyDown
        id = signposter.makeSignpostID()
        captureInterval = signposter.beginInterval("capture-start", id: id)
    }

    mutating func captureDidStart(at instant: MonotonicInstant) {
        captureStarted = instant
        end(&captureInterval, "capture-start")
    }

    mutating func released(at instant: MonotonicInstant) {
        released = instant
        releaseInterval = signposter.beginInterval("release-to-cmdv", id: id)
    }

    mutating func sttDidStart(at instant: MonotonicInstant) {
        sttStarted = instant
        sttInterval = signposter.beginInterval("stt-finalize", id: id)
    }

    mutating func sttDidEnd(at instant: MonotonicInstant) {
        sttEnded = instant
        end(&sttInterval, "stt-finalize")
        cleanInterval = signposter.beginInterval("cleanup", id: id)
    }

    mutating func cleanupDidEnd(at instant: MonotonicInstant) {
        cleanEnded = instant
        end(&cleanInterval, "cleanup")
        pasteInterval = signposter.beginInterval("paste", id: id)
    }

    mutating func pasteDidEnd(at instant: MonotonicInstant) {
        pasteEnded = instant
        end(&pasteInterval, "paste")
        end(&releaseInterval, "release-to-cmdv")
    }

    /// Ends any open intervals of a cancelled or failed dictation.
    mutating func abandon() {
        end(&captureInterval, "capture-start")
        end(&sttInterval, "stt-finalize")
        end(&cleanInterval, "cleanup")
        end(&pasteInterval, "paste")
        end(&releaseInterval, "release-to-cmdv")
    }

    func summary(outcome: String) -> LatencySummary? {
        guard let captureStarted, let released, let sttStarted, let sttEnded, let cleanEnded, let pasteEnded else {
            return nil
        }
        func ms(_ duration: Duration) -> Int { Int(duration.milliseconds.rounded()) }
        return LatencySummary(
            totalMs: ms(pasteEnded - released),
            sttMs: ms(sttEnded - sttStarted),
            cleanMs: ms(cleanEnded - sttEnded),
            pasteMs: ms(pasteEnded - cleanEnded),
            captureStartMs: ms(captureStarted - keyDown),
            audioSeconds: (released - captureStarted).milliseconds / 1_000,
            outcome: outcome
        )
    }

    private func end(_ state: inout OSSignpostIntervalState?, _ name: StaticString) {
        guard let open = state else { return }
        signposter.endInterval(name, open)
        state = nil
    }
}
