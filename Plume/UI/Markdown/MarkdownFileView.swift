import SwiftUI

/// Renders a markdown file from disk through `MarkdownView`, live-updating as
/// the file changes underneath it. Not specific to plans — any path in,
/// rendered markdown out.
struct MarkdownFileView: View {
    let path: String

    @State private var store = MarkdownFileStore()

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .onAppear { store.watch(path: path) }
        .onChange(of: path) { _, newPath in store.watch(path: newPath) }
        .onDisappear { store.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let content = store.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownView(content)
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
