import SwiftUI

/// The newest `/btw` exchange, below the chat and above the composer.
///
/// A side question answers out of band and writes nothing to the transcript,
/// so without this there is nothing on screen between asking and reading the
/// panel — the question looks ignored.
///
/// Drawn as a second composer panel — same glass, radius, width and inset —
/// so the question lines up with the text being written below it. The answer
/// is the agent speaking, so it takes the chat's prose face and size.
struct SideQuestionChip: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.chatFontSize) private var chatFontSize

    let exchange: SideQuestion
    let glass: Glass
    let onOpenPanel: () -> Void
    let onDismiss: () -> Void

    static let symbol = "bubble.left.and.bubble.right"

    var body: some View {
        VStack(alignment: .leading, spacing: questionAnswerSpacing) {
            questionLine
            answer
        }
        .padding(dimensions.composerFieldInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
        .plumeTheme(bodySize: chatFontSize)
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
            Image(systemName: Self.symbol)
                .font(typography.caption.font)
                .emphasis(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(typography.caption.font)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var answer: some View {
        switch exchange.state {
        case .pending, .running:
            EmptyView()
        case let .answered(answer):
            scrolling {
                MarkdownView(answer, isAgentVoice: true)
            }
        case let .failed(message):
            scrolling {
                Text(message)
                    .font(typography.body.font)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The answer scrolls rather than growing without limit, so a long one
    /// cannot push the composer off the window. Capped in height rather than
    /// in lines: a short answer takes only the room it needs.
    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: answerMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture(perform: onOpenPanel)
    }

    private let questionLineLimit = 2
    private let questionAnswerSpacing: CGFloat = 12
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
