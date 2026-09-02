import SwiftUI

/// A proposed plan or a question, drawn as itself rather than as tool JSON.
///
/// Read-only unless an `answer` is supplied. A historical transcript row has
/// nothing to answer; a row backed by a live `PendingPermission` gets real
/// controls, because the headless transport can send a structured response.
struct InteractiveToolRow: View {
    /// What the user can send back, when the row is backed by a live request.
    enum Answer {
        case questions([String: String])
        case approvePlan
        case rejectPlan(reason: String)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let payload: InteractiveToolPayload
    /// Whether the agent is still waiting on this. Only the newest message
    /// can be, so the caller decides.
    let isPending: Bool
    /// Non-nil only while a live request backs this row.
    var answer: ((Answer) -> Void)?

    @State private var answerState = PermissionAnswerState()
    @State private var rejectionReason = ""

    private var isAnswerable: Bool { answer != nil }

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
        if let answer {
            TextField("Reason (optional, sent on reject)", text: $rejectionReason)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: chatFontSize * 0.85))
            HStack(spacing: 8) {
                Button("Approve") { answer(.approvePlan) }
                    .keyboardShortcut(.defaultAction)
                Button("Reject") { answer(.rejectPlan(reason: rejectionReason)) }
                Spacer()
            }
            .font(.system(size: chatFontSize * 0.85))
        } else {
            answerHint("Approve or reject in the terminal.")
        }
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
                    optionRow(option, in: question)
                }
            }
        }
        if let answer {
            HStack {
                Button("Send answer") { answer(.questions(answerState.answers(for: questions))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!answerState.isComplete(for: questions))
                Spacer()
            }
            .font(.system(size: chatFontSize * 0.85))
        } else {
            answerHint("Answer in the terminal.")
        }
    }

    @ViewBuilder
    private func optionRow(
        _ option: InteractiveToolPayload.AskedQuestion.Option,
        in question: InteractiveToolPayload.AskedQuestion
    ) -> some View {
        let isSelected = answerState.isSelected(option.label, for: question)
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: glyph(forSelected: isSelected, multiSelect: question.multiSelect))
                .imageScale(.small)
                .foregroundStyle(glyphStyle(isSelected: isSelected))
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
        .background(optionWash(isSelected: isSelected), in: .rect(cornerRadius: 6))
        .contentShape(.rect)

        if isAnswerable {
            Button {
                answerState.toggle(option.label, for: question)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func glyphStyle(isSelected: Bool) -> AnyShapeStyle {
        isSelected && isAnswerable ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
    }

    private func glyph(forSelected isSelected: Bool, multiSelect: Bool) -> String {
        guard isAnswerable else { return "circle" }
        if multiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func optionWash(isSelected: Bool) -> Color {
        isSelected && isAnswerable
            ? Color.accentColor.opacity(0.15)
            : Color.secondary.opacity(0.08)
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
