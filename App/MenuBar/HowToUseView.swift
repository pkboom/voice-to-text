import SwiftUI

/// The "How to Use" window: opened from the menu, and once automatically on first launch.
struct HowToUseView: View {
    static let windowID = "how-to-use"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Type with your voice")
                    .font(.title.weight(.semibold))
                Text("Works in any app. Apple Speech runs fully on this Mac; the OpenAI engine sends audio to OpenAI.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Click where you want to type",
                     detail: "A message box, a document, a search field…")
                Step(number: 2, title: "Hold Right Option and speak",
                     detail: "Use the ⌥ key to the right of the space bar. Keep holding while you talk (up to 90 seconds).")
                Step(number: 3, title: "Let go",
                     detail: "Your words appear at the cursor a moment later.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Menu-bar icon").font(.headline)
                IconRow(symbol: "mic", color: .primary, text: "Ready")
                IconRow(symbol: "mic.fill", color: .red, text: "Listening")
                IconRow(symbol: "waveform", color: .primary, text: "Turning speech into text")
                IconRow(symbol: "exclamationmark.triangle", color: .primary, text: "Something went wrong. Open the menu for details.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Good to know").font(.headline)
                Tip("The text is also left on your clipboard, replacing what was there.")
                Tip("All four permissions in the menu need a ✓. Click one to fix it.")
                Tip("For OpenAI transcription, add your API key (OpenAI API Key… in the menu), then pick the OpenAI engine under Engine.")
                Tip("Keep mic warm makes dictation start faster, but the mic stays on (orange dot) while the app runs.")
            }
        }
        .padding(28)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct IconRow: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
        }
    }
}

private struct Tip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
