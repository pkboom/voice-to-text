import Testing
@testable import VoiceToTextCore

@Suite struct EngineRegistryTests {
    private let registry = EngineRegistry([
        .init(descriptor: .apple) { MockTranscriptionEngine(descriptor: .apple) },
        .init(descriptor: .mock) { MockTranscriptionEngine(descriptor: .mock) },
    ])

    @Test func standardRegistryShipsAppleThenOpenAIMini() throws {
        let standard = EngineRegistry.standard(openAIKey: { nil })
        #expect(standard.descriptors == [.apple, .openAIMini])
        #expect(EngineDescriptor.apple.id == EngineID("apple"))
        #expect(EngineDescriptor.apple.isStreaming)
        #expect(!EngineDescriptor.openAIMini.isStreaming)
        let engine = try #require(standard.makeEngine(for: .apple))
        #expect(engine is AppleSpeechEngine)
        let mini = try #require(standard.makeEngine(for: .openAIMini) as? OpenAITranscriptionEngine)
        #expect(mini.model == "gpt-4o-mini-transcribe")
    }

    @Test func appleResolves() throws {
        #expect(registry.descriptor(for: .apple) == .apple)
        let engine = try #require(registry.makeEngine(for: .apple))
        #expect(engine.descriptor.id == .apple)
    }

    @Test func mockResolves() throws {
        #expect(registry.descriptor(for: EngineDescriptor.mock.id) == .mock)
        let engine = try #require(registry.makeEngine(for: EngineDescriptor.mock.id))
        #expect(engine.descriptor == .mock)
        #expect(engine is MockTranscriptionEngine)
    }

    @Test func descriptorsKeepOrderAndUnknownIDsResolveToNil() {
        #expect(registry.descriptors == [.apple, .mock])
        #expect(registry.descriptor(for: EngineID("parakeet")) == nil)
        #expect(registry.makeEngine(for: EngineID("parakeet")) == nil)
    }

    @Test func eachResolutionMakesAFreshEngine() throws {
        let first = try #require(registry.makeEngine(for: .apple) as? MockTranscriptionEngine)
        let second = try #require(registry.makeEngine(for: .apple) as? MockTranscriptionEngine)
        #expect(first !== second)
    }

    /// The engine contract (documented on `TranscriptionEngine`): `makeSession()` awaits an
    /// in-flight next-analyzer prep instead of building its own; exactly one build per session.
    @Test func makeSessionAwaitsInFlightPrepWithExactlyOneBuild() async throws {
        let engine = MockTranscriptionEngine(preparesNextAnalyzer: true)
        await engine.prepare()
        #expect(await engine.analyzerBuilds == 1)

        let gate = Gate()
        await engine.setBackgroundPrepGate(gate)
        let first = try #require(try await engine.makeSession() as? MockSession)
        #expect(first.analyzerID == 1)

        let second = Task { try await engine.makeSession() }
        while await engine.waitersForPrep == 0 {
            await Task.yield()
        }
        #expect(await engine.analyzerBuilds == 1)

        await engine.setBackgroundPrepGate(Gate())  // hold the prep the second session kicks off
        gate.open()
        let secondSession = try #require(try await second.value as? MockSession)
        #expect(secondSession.analyzerID == 2)
        #expect(await engine.analyzerBuilds == 2)
        #expect(await engine.inlineBuilds == 0)
    }
}
