import SwiftUI

/// A session card's brief, cut to `lineLimit` lines until expanded.
///
/// `isTruncated` reports whether the cut hides text. Two hidden copies, one
/// cut and one whole, lay out at the shown brief's width, and the brief is
/// truncated when the whole copy is taller.
struct DecisionCardBrief: View, ThemedView {
    @Environment(\.theme) var theme

    let text: String
    let isExpanded: Bool
    @Binding var isTruncated: Bool

    static let lineLimit = 3

    @State private var cutHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    var body: some View {
        brief(lineLimit: isExpanded ? nil : Self.lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    measured(lineLimit: Self.lineLimit) { cutHeight = $0 }
                    measured(lineLimit: nil) { wholeHeight = $0 }
                }
                .hidden()
                .accessibilityHidden(true)
            }
            .onChange(of: wholeHeight > cutHeight + 0.5, initial: true) { _, truncated in
                isTruncated = truncated
            }
    }

    private func brief(lineLimit: Int?) -> some View {
        Text(MarkdownCache.inline(text))
            .font(typography.caption.font)
            .emphasis(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    private func measured(lineLimit: Int?, height: @escaping (CGFloat) -> Void) -> some View {
        brief(lineLimit: lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height($0) }
    }
}

/// "Show more" or "Show less" under a `DecisionCardBrief`.
struct DecisionCardBriefToggle: View, ThemedView {
    @Environment(\.theme) var theme

    @Binding var isExpanded: Bool
    let plumeID: String
    let label: String

    var body: some View {
        Button(action: toggle) {
            Label(isExpanded ? "Show less" : "Show more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(typography.caption.font)
        .emphasis(.secondary)
        .plumeID(plumeID, label: label, value: isExpanded ? "expanded" : "collapsed", invoke: toggle)
    }

    private func toggle() { isExpanded.toggle() }
}
