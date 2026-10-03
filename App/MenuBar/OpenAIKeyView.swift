import SwiftUI

/// The "OpenAI API Key" window: paste, save to the Keychain, or remove the key.
struct OpenAIKeyView: View {
    static let windowID = "openai-key"

    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasSavedKey = OpenAIKeyStore.hasSavedKey
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenAI API Key").font(.title2.weight(.semibold))
            Text("Used only by the OpenAI engine. With it selected, each dictation's audio is sent to OpenAI for transcription. The key is stored in your Keychain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(hasSavedKey ? "A key is saved — paste a new one to replace it" : "sk-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }

            HStack {
                if hasSavedKey {
                    Button("Remove Key", role: .destructive, action: remove)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try OpenAIKeyStore.save(key)
            key = ""
            hasSavedKey = true
            errorMessage = nil
            environment.openAIKeyDidChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try OpenAIKeyStore.remove()
            hasSavedKey = false
            errorMessage = nil
            environment.openAIKeyDidChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
