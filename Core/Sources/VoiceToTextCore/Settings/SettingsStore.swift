import Foundation

/// Persisted user settings backed by an injectable `UserDefaults` suite.
///
/// The hold threshold has no UI in v1:
/// `defaults write com.keunbae.VoiceToText holdThresholdMs -int <n>`.
///
/// `@unchecked Sendable`: the only state is a `UserDefaults`, which is documented thread-safe.
public final class SettingsStore: @unchecked Sendable {
    public enum Key {
        public static let engineID = "engineID"
        public static let holdThresholdMs = "holdThresholdMs"
        public static let keepMicWarm = "keepMicWarm"
    }

    public static let defaultEngineID: EngineID = .apple
    public static let defaultHoldThresholdMs = 300

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var engineID: EngineID {
        get { defaults.string(forKey: Key.engineID).map(EngineID.init(rawValue:)) ?? Self.defaultEngineID }
        set { defaults.set(newValue.rawValue, forKey: Key.engineID) }
    }

    /// Minimum hold in milliseconds. Missing or non-positive values fall back to 300.
    public var holdThresholdMs: Int {
        get {
            let value = defaults.integer(forKey: Key.holdThresholdMs)
            return value > 0 ? value : Self.defaultHoldThresholdMs
        }
        set { defaults.set(newValue, forKey: Key.holdThresholdMs) }
    }

    public var holdThreshold: Duration { .milliseconds(holdThresholdMs) }

    public var keepMicWarm: Bool {
        get { defaults.bool(forKey: Key.keepMicWarm) }
        set { defaults.set(newValue, forKey: Key.keepMicWarm) }
    }
}
