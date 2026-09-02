import SwiftUI

/// A proposed plan or a question, drawn as itself rather than as tool JSON.
///
/// Read-only unless an `answer` is supplied. A historical transcript row has
/// nothing to answer; a row backed by a live `PendingPermission` gets real
/// controls, because the headless transport can send a structured response.
struct InteractiveToolRow: View, ThemedView {
    /// What the user can send back, when the row is backed by a live request.
    enum Answer {
        case questions([String: String])
        case approvePlan
        case rejectPlan(reason: String)
    }

    @Environment(\.theme) var theme

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
                .font(typography.caption.mono)
                .emphasis(.subtle)
                .chatTextColumn()
        }
        if let answer {
            TextField("Reason (optional, sent on reject)", text: $rejectionReason)
                .textFieldStyle(.roundedBorder)
                .font(typography.caption.font)
            HStack(spacing: 8) {
                Button("Approve") { answer(.approvePlan) }
                    .keyboardShortcut(.defaultAction)
                Button("Reject") { answer(.rejectPlan(reason: rejectionReason)) }
                Spacer()
            }
            .font(typography.caption.font)
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
                        .font(typography.caption.semibold)
                        .emphasis(.subtle)
                        .chatTextColumn()
                }
                Text(question.question)
                    .font(typography.caption.font)
                    .textSelection(.enabled)
                    .chatTextColumn()
                if question.multiSelect {
                    Text("Choose any number")
                        .font(typography.caption.font)
                        .emphasis(.subtle)
                        .chatTextColumn()
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
            .font(typography.caption.font)
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
                    .font(typography.body.medium)
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(typography.caption.font)
                        .emphasis(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(optionWash(isSelected: isSelected), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .chatTextColumn()

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
        .role(colors.selection, when: isSelected && isAnswerable, otherwise: .subtle)
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
            ? colors.selection.emphasized(.divider, in: colors)
            : colors.surfaceTint
    }

    // MARK: - Chrome

    private func header(symbol: String, title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(typography.caption.semibold)
            .foregroundStyle(AnyShapeStyle.role(pendingRole, when: isPending, otherwise: .secondary))
            .chatTextColumn()
    }

    /// A question only waits on the user; approving a plan sets work going.
    private var pendingRole: Color {
        switch payload {
        case .questions: colors.attention
        case .plan: colors.warning
        }
    }

    /// Only worth saying while the agent is actually waiting — on a settled
    /// plan it is just noise.
    @ViewBuilder
    private func answerHint(_ text: String) -> some View {
        if isPending {
            Text(text)
                .font(typography.caption.font)
                .emphasis(.subtle)
        }
    }

    private var washColor: Color {
        colors.surfaceTint
    }

    /// A pending row carries its hue on the border only. Washing the card as
    /// well would double-signal one that already has a tinted header.
    private var borderColor: Color {
        isPending
            ? pendingRole.emphasized(.disabled, in: colors)
            : colors.divider
    }
}
