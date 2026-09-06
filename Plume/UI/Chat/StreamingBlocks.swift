import SwiftUI

/// The turn in flight, drawn in the assistant's own idiom so the text does not
/// change appearance when the transcript takes over.
///
/// Thinking stays plain rather than reusing `ThinkingRow`: that row is a
/// disclosure the reader opens, and a stream that is still arriving has
/// nothing to disclose yet — it just wants to be legible and dim.
struct StreamingBlocks: View, ThemedView {
    @Environment(\.theme) var theme

    let overlay: ChatStreamHandoff.Overlay
    /// What the stream is drawn below, within the message holding it. Nil at
    /// the standalone mount, where the list row around it pays the gap.
    var follows: ChatBlockSpacing.Kind?

    @State private var settings = AppSettings.shared
    @State private var progress = RevealProgress()
    @State private var revealedCount: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !overlay.thinking.isEmpty {
                Text(overlay.thinking)
                    .font(typography.body.font)
                    .emphasis(.subtle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listItemPadding(vertical: false)
            }
            if !overlay.text.isEmpty {
                if settings.animateCharacterReveal {
                    CharacterReveal(revealedCount: revealedCount, text: overlay.text) { revealed in
                        MarkdownView(revealed, isAgentVoice: true)
                    }
                } else {
                    MarkdownView(overlay.text, isAgentVoice: true)
                }
            }
        }
        .padding(.top, ChatBlockSpacing.streamingTopInset(previous: follows, dimensions: dimensions))
        .onChange(of: overlay.text, initial: true) { _, text in
            withAnimation(progress.advance(to: text)) {
                revealedCount = Double(text.count)
            }
        }
    }
}
