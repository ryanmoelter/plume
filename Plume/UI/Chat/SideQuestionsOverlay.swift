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
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sideQuestions.reversed()) { exchange in
                            SideQuestionRow(exchange: exchange)
                        }
                    }
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
            Image(systemName: "questionmark.bubble")
                .emphasis(.secondary)
            Text("Side questions")
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
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.question)
                .font(typography.body.font)
            answerView
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 8))
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
            Text(answer)
                .font(typography.caption.font)
                .emphasis(.secondary)
        case .failed(let message):
            Text(message)
                .font(typography.caption.font)
                .foregroundStyle(.red)
        }
    }
}
