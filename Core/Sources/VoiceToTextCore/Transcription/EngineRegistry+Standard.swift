extension EngineRegistry {
    /// The engines the app ships, in menu order, with their factories bound. The single source of
    /// truth for the shipped engine list (the Engine submenu reads `descriptors`).
    ///
    /// `openAIKey` is read by the OpenAI engine whenever they need the key (the app passes its
    /// Keychain reader).
    public static func standard(openAIKey: @escaping OpenAITranscriptionEngine.APIKeyProvider) -> EngineRegistry {
        EngineRegistry([
            .init(descriptor: .apple) { AppleSpeechEngine() },
            .init(descriptor: .openAIMini) {
                OpenAITranscriptionEngine(model: "gpt-4o-mini-transcribe", descriptor: .openAIMini, apiKey: openAIKey)
            },
        ])
    }
}
