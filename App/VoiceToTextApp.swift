import SwiftUI
import VoiceToTextCore

@main
struct VoiceToTextApp: App {
    @State private var environment: AppEnvironment

    init() {
        let environment = AppEnvironment()
        environment.start()
        _environment = State(initialValue: environment)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(environment: environment)
        } label: {
            StatusIcon(state: environment.coordinator.state, hotkeyActive: environment.hotkey.isTapActive)
        }
    }
}
