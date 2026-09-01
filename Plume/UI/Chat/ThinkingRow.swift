import SwiftUI

/// A thinking block, collapsed and dimmed by default.
///
/// Real transcripts sometimes carry a thinking block with no text (verified
/// against captured sessions) — render nothing for that case rather than an
/// empty expander with nothing to disclose.
struct ThinkingRow: View {
    let text: String

    @State private var expanded = false

    var body: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Text("Thinking")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .opacity(0.7)
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
