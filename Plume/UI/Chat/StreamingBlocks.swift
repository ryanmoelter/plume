import SwiftUI

/// The turn in flight, drawn in the assistant's own idiom so the text does not
/// change appearance when the transcript takes over.
///
/// Thinking stays plain rather than reusing `ThinkingRow`: that row is a
/// disclosure the reader opens, and a stream that is still arriving has
/// nothing to disclose yet — it just wants to be legible and dim.
struct StreamingBlocks: View {
    @Environment(\.chatFontSize) private var chatFontSize

    let overlay: ChatStreamHandoff.Overlay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !overlay.thinking.isEmpty {
                Text(overlay.thinking)
                    .font(.system(size: chatFontSize * 0.9))
                    .emphasis(.subtle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listItemPadding(vertical: false)
            }
            if !overlay.text.isEmpty {
                MarkdownView(overlay.text)
            }
        }
    }
}
