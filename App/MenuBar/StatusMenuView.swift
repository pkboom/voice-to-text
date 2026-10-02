import SwiftUI
import VoiceToTextCore

/// The whole v1 UI (Decision E): engine status, Engine submenu, hotkey label, permissions,
/// Keep mic warm, Quit. No Settings window.
struct StatusMenuView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        Text(engineStatusLine)
        if case .failed = environment.coordinator.engineState {
            Button("Retry") { environment.retryEngine() }
        }
        if environment.coordinator.state == .error, let message = environment.coordinator.lastErrorDescription {
            Text("Last dictation failed: \(message)")
        }

        Divider()

        Menu("Engine") {
            ForEach(environment.registry.descriptors) { descriptor in
                Toggle(descriptor.displayName, isOn: Binding(
                    get: { environment.selectedEngineID == descriptor.id },
                    set: { isOn in
                        if isOn { environment.selectEngine(descriptor.id) }
                    }
                ))
            }
        }
        Text(environment.hotkey.isTapActive ? "Hotkey: Right Option" : "Hotkey: Right Option (needs Input Monitoring)")

        Divider()

        Section("Permissions") {
            ForEach(PermissionsManager.Grant.allCases) { grant in
                Button(permissionTitle(grant)) {
                    Task { await environment.permissions.openSettings(for: grant) }
                }
            }
        }

        Divider()

        Toggle("Keep mic warm", isOn: $environment.keepMicWarm)

        Divider()

        Button("Quit VoiceToText") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var engineStatusLine: String {
        let name = environment.coordinator.engineDescriptor.displayName
        return switch environment.coordinator.engineState {
        case .notReady: "\(name): not ready"
        case .downloading(let progress): "\(name): downloading model \(Int((progress * 100).rounded()))%"
        case .ready: "\(name): ready"
        case .failed(let error): "\(name): failed — \(error.localizedDescription)"
        }
    }

    private func permissionTitle(_ grant: PermissionsManager.Grant) -> String {
        switch environment.permissions.status(of: grant) {
        case .granted: "✓ \(grant.displayName)"
        case .denied: "✗ \(grant.displayName) — Open Settings…"
        case .notDetermined: "✗ \(grant.displayName) — Request…"
        }
    }
}
