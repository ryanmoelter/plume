import SwiftUI

/// Every `/btw` exchange for a tab, over the chat.
///
/// Side questions don't chain with each other — each is answered from main
/// context independently — so this renders an unordered list of exchanges
/// rather than a thread the way `SubagentTranscriptOverlay` renders a
/// conversation.
struct SideQuestionsOverlay: View, ThemedView {
    @Environment(\.theme) var theme

    let sideQuestions: [SideQuestion]
    var glass: Glass = .regular
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sideQuestions.isEmpty {
                Text("Nothing asked yet. Try /btw followed by a question.")
                    .font(typography.body.font)
                    .emphasis(.subtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sideQuestions.reversed().enumerated()), id: \.element.id) { index, exchange in
                            if index > 0 { Divider() }
                            SideQuestionRow(exchange: exchange)
                        }
                    }
                    .frame(maxWidth: dimensions.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                }
            }
        }
        .glassEffect(glass, in: .rect(cornerRadius: 12))
        .listItemPadding(bleed: true)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: SideQuestionChip.symbol)
                .emphasis(.secondary)
            Text("Side chats")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .plumeID(AccessibilityID.sideQuestionsClose)
        }
        .padding(12)
    }
}

private struct SideQuestionRow: View, ThemedView {
    @Environment(\.theme) var theme
    let exchange: SideQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exchange.question)
                    .font(typography.body.font)
                    .textSelection(.enabled)
                footer(copying: exchange.question, label: "Copy prompt", at: exchange.askedAt)
            }
            .padding(10)
            .background(colors.surfaceTint, in: .rect(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .trailing)
            answerView
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var answerView: some View {
        switch exchange.state {
        case .pending, .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking…")
                    .emphasis(.subtle)
            }
            .font(typography.caption.font)
        case .answered(let answer):
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(answer, isAgentVoice: true)
                    // Each block pads itself off the chat list's edges, which
                    // would indent the answer from the question above it.
                    .padding(.horizontal, -dimensions.horizontalEdgePadding)
                    .textSelection(.enabled)
                footer(copying: answer, label: "Copy response as markdown", at: exchange.answeredAt)
            }
        case .failed(let message):
            Text(message)
                .font(typography.body.font)
                .foregroundStyle(.red)
        }
    }

    private func footer(copying text: String, label: String, at date: Date?) -> some View {
        HStack(spacing: 4) {
            ChatCopyButton(markdown: text, isRevealed: true, label: label, isFloating: false)
            if let date {
                Text(ChatTimestampFormat.string(for: date, now: .now))
                    .font(typography.caption.font)
                    .emphasis(.subtle)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        // Lands the glyph, not its hover circle, on the text's edge.
        .padding(.leading, -CopyGlyph.inset)
    }
}
