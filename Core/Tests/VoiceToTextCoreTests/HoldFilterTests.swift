import Testing
@testable import VoiceToTextCore

@Suite struct HoldFilterTests {
    let clock = TestClock()

    private func hold(_ filter: inout HoldFilter, for duration: Duration) -> HoldFilter.Decision {
        #expect(filter.keyDown(at: clock.now()) == .started)
        clock.advance(by: duration)
        return filter.keyUp(at: clock.now())
    }

    @Test func holdOf299msIsDiscarded() {
        var filter = HoldFilter()
        #expect(hold(&filter, for: .milliseconds(299)) == .tooShort(.milliseconds(299)))
    }

    @Test func holdOf300msIsAccepted() {
        var filter = HoldFilter()
        #expect(hold(&filter, for: .milliseconds(300)) == .accepted(.milliseconds(300)))
    }

    @Test func chordCancelsTheHoldAndTheLaterKeyUpIsIgnored() {
        var filter = HoldFilter()
        #expect(filter.keyDown(at: clock.now()) == .started)
        clock.advance(by: .milliseconds(500))
        #expect(filter.chord(at: clock.now()) == .chordCancel)
        clock.advance(by: .milliseconds(500))
        #expect(filter.keyUp(at: clock.now()) == .ignored)
    }

    @Test func chordWithoutHoldIsIgnored() {
        var filter = HoldFilter()
        #expect(filter.chord(at: clock.now()) == .ignored)
    }

    @Test func customThresholdIsRespected() {
        var filter = HoldFilter(minimumHold: .milliseconds(500))
        #expect(hold(&filter, for: .milliseconds(499)) == .tooShort(.milliseconds(499)))
        #expect(hold(&filter, for: .milliseconds(500)) == .accepted(.milliseconds(500)))
    }

    @Test func ninetySecondsForceEnds() {
        var filter = HoldFilter()
        #expect(filter.keyDown(at: clock.now()) == .started)
        #expect(filter.deadline == clock.now().advanced(by: .seconds(90)))
        clock.advance(by: .milliseconds(89_999))
        #expect(filter.checkTimeout(at: clock.now()) == .ignored)
        clock.advance(by: .milliseconds(1))
        #expect(filter.checkTimeout(at: clock.now()) == .forceEnd(.seconds(90)))
        #expect(!filter.isHeld)
    }

    @Test func keyUpAfterForceEndIsIgnored() {
        var filter = HoldFilter()
        _ = filter.keyDown(at: clock.now())
        clock.advance(by: .seconds(90))
        #expect(filter.checkTimeout(at: clock.now()) == .forceEnd(.seconds(90)))
        clock.advance(by: .seconds(5))
        #expect(filter.keyUp(at: clock.now()) == .ignored)
        // A fresh hold works normally afterwards.
        #expect(hold(&filter, for: .seconds(1)) == .accepted(.seconds(1)))
    }

    @Test func repeatedKeyDownWhileHeldIsIgnored() {
        var filter = HoldFilter()
        #expect(filter.keyDown(at: clock.now()) == .started)
        clock.advance(by: .milliseconds(100))
        #expect(filter.keyDown(at: clock.now()) == .ignored)
        clock.advance(by: .milliseconds(200))
        #expect(filter.keyUp(at: clock.now()) == .accepted(.milliseconds(300)))
    }
}
