extension EngineRegistry {
    /// The engines v1 ships, in menu order, with their factories bound. The single source of truth
    /// for the shipped engine list (the Engine submenu reads `descriptors`).
    public static let standard = EngineRegistry([
        .init(descriptor: .apple) { AppleSpeechEngine() },
    ])
}
