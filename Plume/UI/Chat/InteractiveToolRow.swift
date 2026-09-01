import SwiftUI

/// A proposed plan or a question, drawn as itself rather than as tool JSON.
///
/// Read-only: this shows what Claude asked, it does not answer it. Answering
/// needs a structured send path the composer does not have — see
/// `docs/agent-transport.md`.
struct InteractiveToolRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let payload: InteractiveToolPayload
    /// Whether the agent is still waiting on this. Only the newest message
    /// can be, so the caller decides.
    let isPending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch payload {
            case .plan(let markdown, let filePath):
                planBody(markdown: markdown, filePath: filePath)
            case .questions(let questions):
                questionsBody(questions)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(washColor, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private func planBody(markdown: String, filePath: String?) -> some View {
        header(symbol: "list.clipboard", title: "Proposed plan")
        MarkdownView(markdown)
        if let filePath {
            Text((filePath as NSString).lastPathComponent)
                .font(.system(size: chatFontSize * 0.75, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        answerHint("Approve or reject in the terminal.")
    }

    // MARK: - Questions

    @ViewBuilder
    private func questionsBody(_ questions: [InteractiveToolPayload.AskedQuestion]) -> some View {
        header(symbol: "questionmark.bubble", title: questions.count == 1 ? "Question" : "Questions")
        ForEach(questions) { question in
            VStack(alignment: .leading, spacing: 6) {
                if !question.header.isEmpty {
                    Text(question.header.uppercased())
                        .font(.system(size: chatFontSize * 0.7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(question.question)
                    .font(.system(size: chatFontSize))
                    .textSelection(.enabled)
                if question.multiSelect {
                    Text("Choose any number")
                        .font(.system(size: chatFontSize * 0.72))
                        .foregroundStyle(.tertiary)
                }
                ForEach(question.options) { option in
                    optionRow(option)
                }
            }
        }
        answerHint("Answer in the terminal.")
    }

    private func optionRow(_ option: InteractiveToolPayload.AskedQuestion.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: chatFontSize * 0.9, weight: .medium))
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(.system(size: chatFontSize * 0.8))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    // MARK: - Chrome

    private func header(symbol: String, title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: chatFontSize * 0.8, weight: .semibold))
            .foregroundStyle(isPending ? Color.orange : .secondary)
    }

    /// Only worth saying while the agent is actually waiting — on a settled
    /// plan it is just noise.
    @ViewBuilder
    private func answerHint(_ text: String) -> some View {
        if isPending {
            Text(text)
                .font(.system(size: chatFontSize * 0.72))
                .foregroundStyle(.tertiary)
        }
    }

    private var washColor: Color {
        (ThemeChrome.foreground(for: colorScheme) ?? .primary).opacity(0.05)
    }

    private var borderColor: Color {
        isPending ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.25)
    }
}
