import Testing
@testable import VoiceToTextCore

@Suite struct LatencyTests {
    @Test func summaryLineMatchesTheReportFormat() {
        let summary = LatencySummary(totalMs: 812, sttMs: 540, cleanMs: 0, pasteMs: 35, captureStartMs: 60, audioSeconds: 10.456, outcome: "passthrough")
        #expect(summary.line == "total_ms=812 stt_ms=540 clean_ms=0 paste_ms=35 capture_start_ms=60 audio_s=10.46 outcome=passthrough")
    }

    @Test func traceComputesStageDurations() throws {
        let clock = TestClock()
        var trace = DictationLatencyTrace(keyDown: clock.now())
        clock.advance(by: .milliseconds(60))
        trace.captureDidStart(at: clock.now())
        clock.advance(by: .seconds(10))
        trace.released(at: clock.now())
        clock.advance(by: .milliseconds(5))
        trace.sttDidStart(at: clock.now())
        clock.advance(by: .milliseconds(540))
        trace.sttDidEnd(at: clock.now())
        trace.cleanupDidEnd(at: clock.now())
        clock.advance(by: .milliseconds(35))
        trace.pasteDidEnd(at: clock.now())

        let summary = try #require(trace.summary(outcome: "passthrough"))
        #expect(summary == LatencySummary(totalMs: 580, sttMs: 540, cleanMs: 0, pasteMs: 35, captureStartMs: 60, audioSeconds: 10, outcome: "passthrough"))
    }

    @Test func incompleteTraceHasNoSummary() {
        var trace = DictationLatencyTrace(keyDown: TestClock().now())
        trace.abandon()
        #expect(trace.summary(outcome: "raw") == nil)
    }
}
