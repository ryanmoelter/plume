import SwiftUI

/// The thinking of the turn in flight, drawn plain rather than as a
/// `ThinkingRow`: that row is a disclosure the reader opens, and thinking
/// that is still arriving has nothing to disclose yet — it just wants to be
/// legible and dim.
///
/// The turn's prose is not here. Each of its blocks is an ordinary
/// `.markdown` piece that types itself out — see `RevealedMarkdownBlock`.
struct StreamingBlocks: View, ThemedView {
    @Environment(\.theme) var theme

    let overlay: ChatStreamHandoff.Overlay

    var body: some View {
        Text(overlay.thinking)
            .font(typography.body.font)
            .emphasis(.subtle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listItemPadding(vertical: false)
    }
}
