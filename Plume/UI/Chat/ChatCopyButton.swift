import AppKit
import SwiftUI

/// Copies markdown to the pasteboard, revealed on hover.
///
/// The same affordance `CodeBlockCopyButton` gives a code block, for the rest
/// of the chat: a table's own source, and a whole reply's.
struct ChatCopyButton: View, ThemedView {
    @Environment(\.theme) var theme

    /// The one copy glyph in the chat, shared with `CodeBlockCopyButton`.
    /// Copying markdown and copying code are the same act on different text,
    /// so distinguishing them by icon only asked the reader to learn a
    /// difference that carries no meaning.
    static let symbol = "doc.on.doc"

    let markdown: String
    let isRevealed: Bool
    var label: String
    /// Set for a button that floats over content, which needs a chip behind
    /// it to stay legible. An inline one sits on the surface already.
    var isFloating: Bool = true

    @State private var didCopy = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: didCopy ? "checkmark" : Self.symbol)
                .font(.system(size: 11, weight: .medium))
                .modifier(CopyGlyphStyle(isFloating: isFloating, didCopy: didCopy))
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

/// The two treatments a copy glyph takes: a chip where it floats over
/// content, dimmed and bare where it sits inline on the surface.
private struct CopyGlyphStyle: ViewModifier, ThemedView {
    @Environment(\.theme) var theme

    let isFloating: Bool
    let didCopy: Bool

    func body(content: Content) -> some View {
        if isFloating {
            content
                .foregroundStyle(colors.foreground)
                .padding(6)
                .background(colors.surface(.backgroundTint), in: .circle)
        } else {
            content
                .emphasis(didCopy ? .primary : .subtle)
                .padding(2)
                .contentShape(.rect)
        }
    }
}
