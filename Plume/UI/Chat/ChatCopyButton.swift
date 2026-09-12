import AppKit
import SwiftUI

/// Copies markdown to the pasteboard, revealed on hover.
///
/// The same affordance `CodeBlockCopyButton` gives a code block, for the rest
/// of the chat: a table's own source, and a whole reply's.
struct ChatCopyButton: View, ThemedView {
    @Environment(\.theme) var theme

    let markdown: String
    let isRevealed: Bool
    var symbol: String = "doc.on.doc"
    var label: String

    @State private var didCopy = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: didCopy ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.foreground)
                .padding(6)
                .background(colors.surface(.backgroundTint), in: .circle)
        }
        .buttonStyle(.plain)
        .opacity(isRevealed || didCopy ? 1 : 0)
        .help(label)
        .accessibilityLabel(label)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}
