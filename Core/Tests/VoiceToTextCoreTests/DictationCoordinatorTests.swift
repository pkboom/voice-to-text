import Testing
@testable import VoiceToTextCore

@MainActor
final class Harness {
    let clock = TestClock()
    let engine: MockTranscriptionEngine
    let capture = MockAudioCapture()
    let inserter = MockInserter()
    let coordinator: DictationCoordinator

    init(engine: MockTranscriptionEngine = MockTranscriptionEngine(), cleaner: any TextCleaner = MockCleaner(), ready: Bool = true) {
        self.engine = engine
        coordinator = DictationCoordinator(
            engine: engine,
            capture: capture,
            cleaner: cleaner,
            inserter: inserter,
            clock: clock
        )
        if ready {
            coordinator.updateEngineState(.ready)
        }
    }

    func down() { coordinator.handle(HotkeyEvent(.down, at: clock.now())) }
    func up() { coordinator.handle(HotkeyEvent(.up, at: clock.now())) }
    func chord() { coordinator.handle(HotkeyEvent(.chord, at: clock.now())) }

    /// Presses, waits for recording, holds for `duration`, releases and waits for completion.
    func dictate(holding duration: Duration) async {
        down()
        await coordinator.settle()
        clock.advance(by: duration)
        up()
        await coordinator.settle()
    }

    var session: MockSession? {
        get async { await engine.sessions.last }
    }
}

@Suite @MainActor struct DictationCoordinatorTests {
    @Test func happyPathCleansRawTranscriptAndInsertsOutcomeOnce() async throws {
        let cleaner = MockCleaner()
        let harness = Harness(engine: MockTranscriptionEngine(transcript: "hello world"), cleaner: cleaner)
        #expect(harness.coordinator.state == .idle)

        harness.down()
        #expect(harness.coordinator.state == .starting)
        await harness.coordinator.settle()
        #expect(harness.coordinator.state == .recording)
        #expect(harness.capture.startCalls == 1)

        harness.clock.advance(by: .seconds(2))
        harness.up()
        #expect(harness.coordinator.state == .processing)
        #expect(harness.capture.stopCalls == 1)
        await harness.coordinator.settle()

        #expect(harness.coordinator.state == .idle)
        #expect(cleaner.inputs == ["hello world"])
        #expect(harness.inserter.inserted == ["HELLO WORLD"])
        let session = try #require(await harness.session)
        #expect(session.stats.finishCalls == 1)
        #expect(session.stats.cancelCalls == 0)
    }

    @Test func passthroughCleanerInsertsTheTranscriptVerbatim() async {
        let transcript = "Ship it tomorrow, then — maybe — Friday.\nThanks!"
        let harness = Harness(engine: MockTranscriptionEngine(transcript: transcript), cleaner: PassthroughCleaner())
        await harness.dictate(holding: .seconds(1))
        #expect(harness.inserter.inserted == [transcript])
        #expect(harness.coordinator.state == .idle)
    }

    @Test func rawOutcomeShowsFallbackFor1500ms() async {
        let cleaner = MockCleaner { CleanupOutcome(text: $0, source: .raw(reason: "timeout")) }
        let harness = Harness(cleaner: cleaner)
        await harness.dictate(holding: .seconds(1))

        #expect(harness.inserter.inserted == ["hello world"])
        #expect(harness.coordinator.state == .fallback)
        let fallback = harness.coordinator.fallbackTask
        harness.clock.advance(by: .milliseconds(1499))
        #expect(harness.coordinator.state == .fallback)
        harness.clock.advance(by: .milliseconds(1))
        await fallback?.value
        #expect(harness.coordinator.state == .idle)
    }

    @Test func shortTapInsertsNothingAndCancels() async throws {
        let harness = Harness()
        await harness.dictate(holding: .milliseconds(299))

        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.state == .idle)
        #expect(harness.capture.stopCalls == 1)
        let session = try #require(await harness.session)
        #expect(session.stats.cancelCalls == 1)
        #expect(session.stats.finishCalls == 0)
    }

    @Test func chordWhileRecordingCancels() async throws {
        let harness = Harness()
        harness.down()
        await harness.coordinator.settle()
        harness.clock.advance(by: .seconds(1))
        harness.chord()
        await harness.coordinator.settle()
        harness.up()
        await harness.coordinator.settle()

        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.state == .idle)
        let session = try #require(await harness.session)
        #expect(session.stats.cancelCalls == 1)
        #expect(session.stats.finishCalls == 0)
    }

    @Test func keyDownIsIgnoredWhenEngineIsNotReady() async {
        let harness = Harness(ready: false)
        #expect(harness.coordinator.state == .notReady)
        await harness.dictate(holding: .seconds(1))

        #expect(harness.coordinator.state == .notReady)
        #expect(harness.capture.startCalls == 0)
        #expect(await harness.engine.sessionsMade == 0)
        #expect(harness.inserter.inserted.isEmpty)

        harness.coordinator.updateEngineState(.downloading(0.5))
        harness.down()
        #expect(harness.coordinator.state == .notReady)
    }

    @Test func engineStateStreamDrivesReadiness() async {
        let engine = MockTranscriptionEngine()
        let harness = Harness(engine: engine, ready: false)
        engine.publish(.downloading(0.4))
        engine.publish(.ready)
        engine.finishStates()
        await harness.coordinator.observeEngineStates()

        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.engineState.isReady)
    }

    @Test func setEngineSwapsEngineAndIgnoresTheOldEnginesStates() async {
        let oldEngine = MockTranscriptionEngine()
        let harness = Harness(engine: oldEngine, ready: false)
        let oldObserver = Task { await harness.coordinator.observeEngineStates() }
        oldEngine.publish(.downloading(0.1))
        while harness.coordinator.engineState.kind != "downloading" {
            await Task.yield()
        }

        let newEngine = MockTranscriptionEngine(descriptor: .apple, transcript: "from the new engine")
        harness.coordinator.setEngine(newEngine)
        #expect(harness.coordinator.state == .notReady)
        #expect(harness.coordinator.engineDescriptor.id == .apple)

        oldEngine.publish(.ready)
        oldEngine.finishStates()
        await oldObserver.value
        #expect(harness.coordinator.state == .notReady, "the old engine's .ready must be ignored")

        newEngine.publish(.ready)
        newEngine.finishStates()
        await harness.coordinator.observeEngineStates()
        #expect(harness.coordinator.state == .idle)

        await harness.dictate(holding: .seconds(1))
        #expect(harness.inserter.inserted == ["FROM THE NEW ENGINE"])
        #expect(await newEngine.sessionsMade == 1)
        #expect(await oldEngine.sessionsMade == 0)
    }

    @Test func engineFinishThrowGoesToErrorState() async {
        let harness = Harness(engine: MockTranscriptionEngine(finishError: MockError("stt failed")))
        await harness.dictate(holding: .seconds(1))

        #expect(harness.coordinator.state == .error)
        #expect(harness.coordinator.lastErrorDescription != nil)
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test func makeSessionThrowGoesToErrorStateWithoutCapture() async {
        let harness = Harness(engine: MockTranscriptionEngine(makeSessionError: MockError("no analyzer")))
        await harness.dictate(holding: .seconds(1))

        #expect(harness.coordinator.state == .error)
        #expect(harness.capture.startCalls == 0)
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test func captureStartFailureCancelsSessionAndErrors() async throws {
        let harness = Harness()
        harness.capture.startError = MockError("mic busy")
        harness.down()
        await harness.coordinator.settle()

        #expect(harness.coordinator.state == .error)
        let session = try #require(await harness.session)
        #expect(session.stats.cancelCalls == 1)
    }

    @Test func nextDictationAfterErrorSucceeds() async {
        let harness = Harness()
        harness.inserter.error = MockError("paste blocked")
        await harness.dictate(holding: .seconds(1))
        #expect(harness.coordinator.state == .error)

        harness.inserter.error = nil
        await harness.dictate(holding: .seconds(1))
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.lastErrorDescription == nil)
        #expect(harness.inserter.inserted == ["HELLO WORLD"])
    }

    @Test func watchdogForceEndIsProcessedOnceAndLaterKeyUpIgnored() async throws {
        let harness = Harness()
        harness.down()
        await harness.coordinator.settle()
        #expect(harness.coordinator.state == .recording)

        let watchdog = try #require(harness.coordinator.watchdogTask)
        harness.clock.advance(by: .seconds(90))
        await watchdog.value
        #expect(harness.coordinator.state == .processing)
        await harness.coordinator.settle()
        #expect(harness.inserter.inserted == ["HELLO WORLD"])

        harness.clock.advance(by: .seconds(3))
        harness.up()
        await harness.coordinator.settle()
        #expect(harness.inserter.inserted.count == 1)
        #expect(harness.coordinator.state == .idle)
        let session = try #require(await harness.session)
        #expect(session.stats.finishCalls == 1)
        #expect(await harness.engine.sessionsMade == 1)
    }

    @Test func releaseBeforeWatchdogCancelsIt() async {
        let harness = Harness()
        await harness.dictate(holding: .seconds(1))
        #expect(harness.coordinator.watchdogTask == nil)
        #expect(harness.clock.pendingSleepers == 0)
    }

    @Test func keyUpDuringStartingCancelsWithoutCapture() async throws {
        let gate = Gate()
        let harness = Harness(engine: MockTranscriptionEngine(makeSessionGate: gate))
        harness.down()
        #expect(harness.coordinator.state == .starting)
        harness.clock.advance(by: .milliseconds(400))
        harness.up()
        gate.open()
        await harness.coordinator.settle()

        #expect(harness.coordinator.state == .idle)
        #expect(harness.capture.startCalls == 0)
        #expect(harness.inserter.inserted.isEmpty)
        let session = try #require(await harness.session)
        #expect(session.stats.cancelCalls == 1)
        #expect(session.stats.finishCalls == 0)
    }

    @Test func chordDuringStartingCancelsWithoutCapture() async throws {
        let gate = Gate()
        let harness = Harness(engine: MockTranscriptionEngine(makeSessionGate: gate))
        harness.down()
        harness.clock.advance(by: .milliseconds(100))
        harness.chord()
        gate.open()
        await harness.coordinator.settle()
        harness.clock.advance(by: .milliseconds(400))
        harness.up()
        await harness.coordinator.settle()

        #expect(harness.coordinator.state == .idle)
        #expect(harness.capture.startCalls == 0)
        #expect(harness.inserter.inserted.isEmpty)
        let session = try #require(await harness.session)
        #expect(session.stats.cancelCalls == 1)
    }

    @Test func keyDownWhileProcessingIsIgnored() async {
        let finishGate = Gate()
        let harness = Harness(engine: MockTranscriptionEngine(finishGate: finishGate))
        harness.down()
        await harness.coordinator.settle()
        harness.clock.advance(by: .seconds(1))
        harness.up()
        #expect(harness.coordinator.state == .processing)

        harness.down()
        #expect(harness.coordinator.state == .processing)
        finishGate.open()
        await harness.coordinator.settle()
        harness.up()
        await harness.coordinator.settle()

        #expect(harness.coordinator.state == .idle)
        #expect(await harness.engine.sessionsMade == 1)
        #expect(harness.inserter.inserted == ["HELLO WORLD"])
    }

    @Test func sttDeadlineIsGenerousAndScalesWithAudio() {
        #expect(DictationCoordinator.sttDeadline(forAudio: .zero) == .seconds(10))
        #expect(DictationCoordinator.sttDeadline(forAudio: .seconds(10)) == .seconds(10))
        #expect(DictationCoordinator.sttDeadline(forAudio: .seconds(20)) == .seconds(15))
        #expect(DictationCoordinator.sttDeadline(forAudio: .seconds(90)) == .seconds(50))
    }

    @Test func hungFinishTimesOutCancelsAndAcceptsTheNextKeyDown() async throws {
        let harness = Harness(engine: MockTranscriptionEngine(finishHangsUntilCancelled: true))
        harness.down()
        await harness.coordinator.settle()
        harness.clock.advance(by: .seconds(1))
        harness.up()
        #expect(harness.coordinator.state == .processing)
        let stuck = try #require(await harness.session)
        let timeout = try #require(harness.coordinator.sttTimeoutTask)

        // 1 s of audio → 10 s deadline, measured from the release.
        harness.clock.advance(by: .milliseconds(9_999))
        #expect(harness.coordinator.state == .processing)
        #expect(stuck.stats.cancelCalls == 0)
        harness.clock.advance(by: .milliseconds(1))
        await timeout.value
        #expect(harness.coordinator.state == .error)
        #expect(harness.coordinator.lastErrorDescription?.hasPrefix("stt: ") == true)
        await harness.coordinator.settle()  // the cancel, and the stuck finish() returning
        #expect(stuck.stats.cancelCalls == 1)
        #expect(stuck.stats.finishCalls == 1)
        #expect(harness.coordinator.state == .error, "the late finish() result is dropped")
        #expect(harness.inserter.inserted.isEmpty)

        harness.down()
        #expect(harness.coordinator.state == .starting)
        await harness.coordinator.settle()
        #expect(harness.coordinator.state == .recording)
        #expect(await harness.engine.sessionsMade == 2)
        #expect(harness.coordinator.lastErrorDescription == nil)
    }

    @Test func finishedSttCancelsItsTimeout() async throws {
        let harness = Harness()
        await harness.dictate(holding: .seconds(1))
        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.sttTimeoutTask == nil)
        harness.clock.advance(by: .seconds(60))
        #expect(harness.coordinator.state == .idle)
        #expect(harness.clock.pendingSleepers == 0)
    }

    @Test func makeSessionDuringInFlightPrepAwaitsItWithOneBuild() async throws {
        let engine = MockTranscriptionEngine(preparesNextAnalyzer: true)
        await engine.prepare()
        let harness = Harness(engine: engine)
        let prepGate = Gate()
        await engine.setBackgroundPrepGate(prepGate)

        await harness.dictate(holding: .seconds(1))
        #expect(harness.inserter.inserted.count == 1)

        // The next analyzer is still being prepared when the key goes down again.
        harness.down()
        while await engine.waitersForPrep == 0 {
            await Task.yield()
        }
        #expect(harness.coordinator.state == .starting)
        #expect(await engine.analyzerBuilds == 1)

        // Hold the prep that the second session kicks off, so the build count is exact.
        await engine.setBackgroundPrepGate(Gate())
        prepGate.open()
        await harness.coordinator.settle()
        #expect(harness.coordinator.state == .recording)
        #expect(await engine.analyzerBuilds == 2)
        #expect(await engine.inlineBuilds == 0)
        let second = try #require(await harness.session)
        #expect(second.analyzerID == 2)

        harness.clock.advance(by: .seconds(1))
        harness.up()
        await harness.coordinator.settle()
        #expect(harness.inserter.inserted.count == 2)
    }

    @Test func sessionIsReleasedAfterDictation() async {
        let engine = MockTranscriptionEngine(retainsSessions: false)
        let harness = Harness(engine: engine)
        weak var weakSession: MockSession?

        harness.down()
        await harness.coordinator.settle()
        weakSession = await engine.lastSession
        #expect(weakSession != nil)
        harness.clock.advance(by: .seconds(1))
        harness.up()
        await harness.coordinator.settle()

        #expect(harness.inserter.inserted.count == 1)
        #expect(harness.capture.sink == nil)
        #expect(weakSession == nil)
    }

    @Test func cancelledSessionIsReleased() async {
        let engine = MockTranscriptionEngine(retainsSessions: false)
        let harness = Harness(engine: engine)
        weak var weakSession: MockSession?

        harness.down()
        await harness.coordinator.settle()
        weakSession = await engine.lastSession
        harness.clock.advance(by: .milliseconds(100))
        harness.up()
        await harness.coordinator.settle()

        #expect(weakSession == nil)
    }

    @Test func chunksFlowFromCaptureDirectlyToSession() async throws {
        let harness = Harness()
        harness.down()
        await harness.coordinator.settle()
        let session = try #require(await harness.session)
        let sink = try #require(harness.capture.sink)
        #expect(sink as? MockSession === session)

        // Off the main actor, like the audio tap thread: each append lands synchronously.
        let delivered = await Task.detached {
            for _ in 0..<3 {
                sink.append(TestAudio.chunk(frames: 1_600))
            }
            return session.stats.chunks
        }.value
        #expect(delivered == 3)
        #expect(session.stats.frames == 4_800)

        harness.clock.advance(by: .seconds(1))
        harness.up()
        await harness.coordinator.settle()
        harness.capture.emit(TestAudio.chunk())
        #expect(session.stats.chunks == 3, "no chunks after capture stopped")
    }

    @Test func consumesEventsFromHotkeySource() async throws {
        let harness = Harness()
        let source = MockHotkeySource()
        try source.start()
        let consumer = Task { await harness.coordinator.consume(source) }

        source.send(HotkeyEvent(.down, at: harness.clock.now()))
        while harness.coordinator.state != .recording {
            await Task.yield()
        }
        harness.clock.advance(by: .seconds(1))
        source.send(HotkeyEvent(.up, at: harness.clock.now()))
        source.finish()
        await consumer.value
        await harness.coordinator.settle()

        #expect(harness.inserter.inserted == ["HELLO WORLD"])
    }

    @Test func emptyTranscriptInsertsNothing() async {
        let harness = Harness(engine: MockTranscriptionEngine(transcript: "  "), cleaner: PassthroughCleaner())
        await harness.dictate(holding: .seconds(1))
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.state == .idle)
    }
}
