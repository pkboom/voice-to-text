import Foundation
import Testing
import VoiceToTextCore

@Suite struct SettingsStoreTests {
    /// A private suite per test, removed afterwards.
    private func withSuite(_ body: (_ suiteName: String) throws -> Void) rethrows {
        let suiteName = "com.keunbae.VoiceToText.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        try body(suiteName)
    }

    @Test func defaults() throws {
        try withSuite { suiteName in
            let store = SettingsStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
            #expect(store.engineID == .apple)
            #expect(store.holdThresholdMs == 300)
            #expect(store.holdThreshold == .milliseconds(300))
            #expect(store.keepMicWarm == false)
        }
    }

    @Test func valuesPersistAcrossInstances() throws {
        try withSuite { suiteName in
            let first = SettingsStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
            first.engineID = EngineID("whisperkit")
            first.holdThresholdMs = 450
            first.keepMicWarm = true

            let second = SettingsStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
            #expect(second.engineID == EngineID("whisperkit"))
            #expect(second.holdThresholdMs == 450)
            #expect(second.holdThreshold == .milliseconds(450))
            #expect(second.keepMicWarm == true)
        }
    }

    @Test func nonPositiveThresholdFallsBackToDefault() throws {
        try withSuite { suiteName in
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.set(0, forKey: SettingsStore.Key.holdThresholdMs)
            #expect(SettingsStore(defaults: defaults).holdThresholdMs == 300)
        }
    }

    @Test func thresholdWrittenAsStringByDefaultsWriteIsRead() throws {
        try withSuite { suiteName in
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.set("400", forKey: SettingsStore.Key.holdThresholdMs)
            #expect(SettingsStore(defaults: defaults).holdThresholdMs == 400)
        }
    }
}
