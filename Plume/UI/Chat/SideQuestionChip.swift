import SwiftUI

/// The newest `/btw` exchange, below the chat and above the composer.
///
/// A side question answers out of band and writes nothing to the transcript,
/// so without this there is nothing on screen between asking and reading the
/// panel — the question looks ignored. Shaped like `CommandRunChip` for the
/// same reason: both report work running beside the conversation rather than
/// in it.
struct SideQuestionChip: View, ThemedView {
    @Environment(\.theme) var theme

    let exchange: SideQuestion
    let onOpenPanel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionLine
            answer
        }
        .padding(10)
        .glassEffect(Glass.regular.tint(colors.surfaceTint), in: .rect(cornerRadius: 10))
        .frame(maxWidth: dimensions.contentWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .plumeID(AccessibilityID.sideQuestionChip, value: chipValue)
    }

    private var questionLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            status
            Text(exchange.question)
                .font(typography.body.font)
                .lineSpacing(typography.body.lineSpacing)
                .lineLimit(questionLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this side question")
            .accessibilityLabel("Dismiss side question")
            .plumeID(AccessibilityID.sideQuestionChipDismiss, invoke: onDismiss)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch exchange.state {
        case .pending, .running:
            WorkingEllipsis(color: colors.activity)
                .font(typography.caption.font)
        case .answered:
            Image(systemName: "questionmark.bubble")
                .font(typography.caption.font)
                .emphasis(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(typography.caption.font)
                .foregroundStyle(.red)
        }
    }

    /// The answer scrolls rather than growing without limit, so a long one
    /// cannot push the composer off the window. Capped in height rather than
    /// in lines: a short answer takes only the room it needs.
    @ViewBuilder
    private var answer: some View {
        switch exchange.state {
        case .pending, .running:
            EmptyView()
        case let .answered(answer):
            scrollingText(answer)
                .emphasis(.secondary)
        case let .failed(message):
            scrollingText(message)
                .foregroundStyle(.red)
        }
    }

    private func scrollingText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(typography.caption.font)
                .lineSpacing(typography.caption.lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: answerMaxHeight)
        // Height follows the text until the cap, so a one-line answer is not
        // padded out to a scroller's worth of empty space.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
        .onTapGesture(perform: onOpenPanel)
    }

    private let questionLineLimit = 2
    private let answerMaxHeight: CGFloat = 220

    /// What a driver reads to tell the states apart without the glyph.
    private var chipValue: String {
        switch exchange.state {
        case .pending, .running: "running"
        case let .answered(answer): answer
        case let .failed(message): "failed: \(message)"
        }
    }
}
