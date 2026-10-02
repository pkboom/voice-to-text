import AppKit
import SwiftUI
import VoiceToTextCore

/// The menu-bar label: one SF Symbol per coordinator state.
struct StatusIcon: View {
    let state: DictationState
    /// `false` while the hotkey tap cannot be created (Input Monitoring missing).
    let hotkeyActive: Bool

    var body: some View {
        switch state {
        case .starting, .recording:
            Image(nsImage: Self.recordingImage)
        default:
            Image(systemName: symbolName)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var symbolName: String {
        switch state {
        case .idle: hotkeyActive ? "mic" : "mic.slash"
        case .starting, .recording: "mic.fill"
        case .processing: "waveform"
        case .fallback: "exclamationmark.circle"
        case .error: "exclamationmark.triangle"
        case .notReady: "arrow.down.circle"
        }
    }

    private var accessibilityText: String {
        switch state {
        case .idle: hotkeyActive ? "VoiceToText idle" : "VoiceToText: hotkey unavailable"
        case .starting, .recording: "VoiceToText recording"
        case .processing: "VoiceToText processing"
        case .fallback: "VoiceToText: inserted raw text"
        case .error: "VoiceToText error"
        case .notReady: "VoiceToText: engine not ready"
        }
    }

    /// A red, non-template `mic.fill` (template images are drawn monochrome by the menu bar).
    private static let recordingImage: NSImage = {
        let base = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceToText recording") ?? NSImage()
        let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? base
        image.isTemplate = false
        return image
    }()
}
