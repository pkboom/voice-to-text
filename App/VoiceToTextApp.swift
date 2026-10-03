import SwiftUI
import VoiceToTextCore

@main
struct VoiceToTextApp: App {
    @State private var environment: AppEnvironment
    @AppStorage("hasShownHowToUse") private var hasShownHowToUse = false

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
                .modifier(ShowHowToUseOnFirstLaunch(hasShown: $hasShownHowToUse))
        }

        Window("How to Use VoiceToText", id: HowToUseView.windowID) {
            HowToUseView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("OpenAI API Key", id: OpenAIKeyView.windowID) {
            OpenAIKeyView(environment: environment)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

/// Opens the How to Use window once, the first time the menu-bar label appears.
private struct ShowHowToUseOnFirstLaunch: ViewModifier {
    @Binding var hasShown: Bool
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard !hasShown else { return }
            hasShown = true
            NSApplication.shared.activate()
            openWindow(id: HowToUseView.windowID)
        }
    }
}
