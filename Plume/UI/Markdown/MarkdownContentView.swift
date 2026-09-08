import SwiftUI

/// Renders markdown through `MarkdownView`, with a placeholder for content
/// that has not arrived. Not specific to plans — any markdown in, rendered
/// markdown out.
///
/// The content comes from the caller rather than from a path here, because
/// whoever shows this usually needs the same text for something else (the
/// plan's title, say) and the file should only be read once. Pair it with a
/// `MarkdownFileStore` to follow a file live.
struct MarkdownContentView: View {
    let content: String?

    var body: some View {
        ScrollView {
            rendered
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    @ViewBuilder
    private var rendered: some View {
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownView(content, isAgentVoice: true)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}
