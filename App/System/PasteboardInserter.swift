import AppKit
import ApplicationServices
import CoreGraphics
import VoiceToTextCore

enum PasteError: Error, LocalizedError {
    case pasteboardWriteFailed
    case accessibilityNotGranted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .pasteboardWriteFailed: "Could not write to the clipboard."
        case .accessibilityNotGranted: "Accessibility is not granted, so Cmd+V could not be sent. The text is on the clipboard."
        case .eventCreationFailed: "Could not create the Cmd+V key events. The text is on the clipboard."
        }
    }
}

/// Inserts text by writing it to the general pasteboard and posting Cmd+V.
///
/// - The text stays on the clipboard; the previous clipboard is not restored.
/// - Cmd+V comes from a `.privateState` source with `flags = .maskCommand` set explicitly, so a
///   still-held (or just-released) Option key cannot leak into the shortcut (R9).
/// - Virtual key 9 is "v" on ANSI/US layouts only (R16).
/// - `insert` returns right after the key-up is posted; the coordinator ends the `paste` and
///   `release-to-cmdv` intervals there (the AC13 endpoint).
final class PasteboardInserter: TextInserter {
    static let vKeyCode: CGKeyCode = 9
    /// Lets the pasteboard change propagate before the target app reads it.
    static let settleDelay: Duration = .milliseconds(30)

    func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw PasteError.pasteboardWriteFailed
        }
        try await Task.sleep(for: Self.settleDelay)

        guard AXIsProcessTrusted() else {
            throw PasteError.accessibilityNotGranted
        }
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            throw PasteError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
