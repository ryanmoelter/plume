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
            CopyGlyph(didCopy: didCopy, alwaysFilled: isFloating)
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

/// The copy glyph and the circle behind it, shared by every copy button in
/// the chat.
///
/// The circle is a fixed-size container rather than padding around the glyph,
/// so swapping the copy icon for the checkmark — two symbols of different
/// width — moves nothing around it.
struct CopyGlyph: View, ThemedView {
    @Environment(\.theme) var theme

    let didCopy: Bool
    /// Set where the glyph floats over content and needs the circle for
    /// legibility rather than as a hover affordance.
    var alwaysFilled: Bool = false
    /// A wider region whose hover reveals the circle, for a button sitting in
    /// a container the reader aims at rather than the button itself. Left
    /// unset, the glyph tracks its own pointer.
    var isContainerHovered: Bool?

    @State private var isHovered = false

    var body: some View {
        // Each state is its own branch, so the swap replaces the image rather
        // than mutating it — `.transition` is what animates that.
        Group {
            if didCopy {
                Image(systemName: "checkmark")
                    .transition(.symbolEffect)
            } else {
                Image(systemName: ChatCopyButton.symbol)
                    .transition(.symbolEffect)
            }
        }
        .font(.system(size: Self.glyphSize, weight: .medium))
        .modifier(CopyGlyphTint(alwaysFilled: alwaysFilled, didCopy: didCopy))
        .animation(.default, value: didCopy)
        .frame(width: Self.diameter, height: Self.diameter)
        .background(showsCircle ? colors.surface(.backgroundTint) : .clear, in: .circle)
        .contentShape(.circle)
        .onHover { isHovered = $0 }
    }

    private var showsCircle: Bool {
        alwaysFilled || isHovered || isContainerHovered == true
    }

    /// How far the circle extends past the glyph on each side. A caller
    /// aligning the glyph to an edge pulls the button back by this much.
    static let inset: CGFloat = (diameter - glyphSize) / 2

    private static let diameter: CGFloat = 22
    private static let glyphSize: CGFloat = 11
}

/// A floating glyph keeps the theme foreground against its chip; an inline
/// one dims to the surrounding text and brightens once the copy lands.
private struct CopyGlyphTint: ViewModifier, ThemedView {
    @Environment(\.theme) var theme

    let alwaysFilled: Bool
    let didCopy: Bool

    func body(content: Content) -> some View {
        if alwaysFilled {
            content.foregroundStyle(colors.foreground)
        } else {
            content.emphasis(didCopy ? .primary : .subtle)
        }
    }
}
