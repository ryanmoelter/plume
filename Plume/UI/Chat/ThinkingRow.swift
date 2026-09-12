import SwiftUI

/// A thinking block, collapsed and dimmed by default.
///
/// Real transcripts sometimes carry a thinking block with no text (verified
/// against captured sessions) — render nothing for that case rather than an
/// empty expander with nothing to disclose.
struct ThinkingRow: View, ThemedView {
    @Environment(\.theme) var theme

    let text: String

    @State private var expanded = false

    var body: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                // Bounded and scrolling inside itself, so expanding a long
                // reasoning block cannot hand the lazy stack an item many
                // times its neighbours' height.
                ScrollView {
                    Text(text)
                        .font(typography.body.font)
                        .emphasis(.subtle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ChatPieceMetrics.maxDisclosedHeight)
                .padding(.top, 4)
            } label: {
                Text("Thinking")
                    .font(typography.body.font)
                    .emphasis(.subtle)
            }
            .listItemPadding(vertical: false)
            .chatItemExpansionProbe(expanded)
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        ThinkingRow(text: "Let me consider the tradeoffs here...")
        ThinkingRow(text: "")
    }
    .padding()
}
