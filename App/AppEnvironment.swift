import Observation
import os
import VoiceToTextCore

/// Composition root: builds and wires every concrete piece, and owns the engine swap.
///
/// This is the **single wiring point** for cleanup: v1 passes `PassthroughCleaner` (identity,
/// AC14); v1.1 selects its cleaner here without touching the coordinator (§9).
@Observable
final class AppEnvironment {
    private static let logger = Logger(subsystem: Latency.subsystem, category: "app")

    let registry: EngineRegistry
    let permissions = PermissionsManager()
    let hotkey: CGEventTapHotkeySource
    let coordinator: DictationCoordinator

    private(set) var selectedEngineID: EngineID

    /// Persisted. When on, the audio engine keeps running between dictations (no mic cold start).
    var keepMicWarm: Bool {
        didSet {
            settings.keepMicWarm = keepMicWarm
            capture.keepWarm = keepMicWarm
        }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let capture: AVAudioEngineCapture
    @ObservationIgnored private var engine: any TranscriptionEngine
    @ObservationIgnored private var engineObserver: Task<Void, Never>?
    @ObservationIgnored private var hotkeyConsumer: Task<Void, Never>?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(settings: SettingsStore = SettingsStore(), registry: EngineRegistry = .standard(openAIKey: OpenAIKeyStore.read)) {
        self.settings = settings
        self.registry = registry

        let engineID = registry.descriptor(for: settings.engineID) != nil ? settings.engineID : SettingsStore.defaultEngineID
        guard let engine = registry.makeEngine(for: engineID) else {
            preconditionFailure("EngineRegistry has no engine for \(engineID)")
        }
        self.engine = engine
        selectedEngineID = engineID
        keepMicWarm = settings.keepMicWarm

        let clock = SystemMonotonicClock()
        capture = AVAudioEngineCapture()
        hotkey = CGEventTapHotkeySource(clock: clock)
        coordinator = DictationCoordinator(
            engine: engine,
            capture: capture,
            cleaner: PassthroughCleaner(),
            inserter: PasteboardInserter(),
            clock: clock,
            holdThreshold: settings.holdThreshold
        )
    }

    /// Called once at launch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.logger.notice("launch engine=\(self.selectedEngineID.rawValue, privacy: .public) keepMicWarm=\(self.keepMicWarm, privacy: .public)")

        hotkeyConsumer = Task { [coordinator, hotkey] in await coordinator.consume(hotkey) }
        hotkey.start()

        observeEngineStates()
        engineTask = Task { [engine] in await engine.prepare() }

        permissions.startMonitoring()
        Task {
            await permissions.requestLaunchPermissions()
            // After the mic prompt, so warming never races the first-launch permission dialog.
            capture.keepWarm = keepMicWarm
        }
    }

    /// The Engine submenu: persist the choice, unload the old engine, prepare the new one and
    /// point the coordinator at it.
    func selectEngine(_ id: EngineID) {
        guard id != selectedEngineID, let newEngine = registry.makeEngine(for: id) else { return }
        Self.logger.notice("engine swap \(self.selectedEngineID.rawValue, privacy: .public) -> \(id.rawValue, privacy: .public)")
        let oldEngine = engine
        engine = newEngine
        selectedEngineID = id
        settings.engineID = id

        engineObserver?.cancel()
        coordinator.setEngine(newEngine)
        observeEngineStates()

        let previous = engineTask
        engineTask = Task {
            await previous?.value
            await oldEngine.unload()
            await newEngine.prepare()
        }
    }

    /// The menu's Retry item (shown while the engine is `.failed`): run `prepare()` again.
    func retryEngine() {
        Self.logger.notice("engine retry \(self.selectedEngineID.rawValue, privacy: .public)")
        let previous = engineTask
        engineTask = Task { [engine] in
            await previous?.value
            await engine.prepare()
        }
    }

    /// The API key window saved or removed the key: re-run `prepare()` if the OpenAI engine is selected.
    func openAIKeyDidChange() {
        guard selectedEngineID == .openAIMini else { return }
        retryEngine()
    }

    private func observeEngineStates() {
        engineObserver = Task { [coordinator] in await coordinator.observeEngineStates() }
    }
}
