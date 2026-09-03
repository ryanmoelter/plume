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
    /// The tool result text once this call is settled — for a plan, the
    /// approval or denial message; nil while pending or for a question,
    /// which doesn't carry a comparable settled message.
    var resultText: String?
    /// Non-nil only while a live request backs this row.
    var answer: ((Answer) -> Void)?
    /// Supplied where the plan overlay is reachable, which is what decides a
    /// live proposal. Nil leaves the row a summary with nothing to open.
    var openPlan: (() -> Void)?

    @State private var answerState = PermissionAnswerState()
    @State private var rejectionReason = ""
    @State private var questionIndex = 0

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

    /// A summary, not the plan itself. The overlay renders the document and
    /// owns the decision, so repeating either here would ask the user to read
    /// the same plan twice and choose in two places.
    @ViewBuilder
    private func planBody(markdown: String, filePath: String?) -> some View {
        header(symbol: "list.clipboard", title: "Proposed plan")
        Text(PlanSummary.firstLine(of: markdown))
            .font(typography.body.medium)
            .chatTextColumn()
        if let filePath {
            Text((filePath as NSString).lastPathComponent)
                .font(typography.caption.mono)
                .emphasis(.subtle)
                .chatTextColumn()
        }
        if isPending, let openPlan {
            Button("Review plan") { openPlan() }
                .font(typography.caption.font)
        } else if !isPending {
            settledPlanState()
        }
    }

    /// Only a rejection has anything worth saying — approval just let the
    /// agent continue, which the rest of the transcript already shows.
    @ViewBuilder
    private func settledPlanState() -> some View {
        if let resultText, PlanResolution.isRejection(resultText) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rejected")
                    .font(typography.caption.semibold)
                    .foregroundStyle(colors.danger)
                if let reason = PlanResolution.rejectionReason(from: resultText) {
                    Text(reason)
                        .font(typography.caption.font)
                        .emphasis(.secondary)
                }
            }
            .chatTextColumn()
        }
    }

    // MARK: - Questions

    @ViewBuilder
    private func questionsBody(_ questions: [InteractiveToolPayload.AskedQuestion]) -> some View {
        header(symbol: "questionmark.bubble", title: questions.count == 1 ? "Question" : "Questions")
        let index = QuestionPaging.clamped(questionIndex, count: questions.count)
        if questions.indices.contains(index) {
            let question = questions[index]
            // Everything already decided, kept in view as a summary so the
            // user can see their answers without paging back for them.
            ForEach(Array(questions.enumerated()), id: \.element.id) { offset, earlier in
                if offset != index, !answerState.selectedLabels(for: earlier).isEmpty {
                    answeredSummary(earlier)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if questions.count > 1 {
                    pagingControls(current: index, count: questions.count)
                }
                if !question.header.isEmpty {
                    Text(question.header.uppercased())
                        .font(typography.caption.semibold)
                        .emphasis(.subtle)
                        .chatTextColumn()
                }
                Text(question.question)
                    .font(proseTypography.body.medium)
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
            let action = QuestionPrimaryAction.next(for: questions, in: answerState)
            HStack {
                Spacer()
                Button(action.label) {
                    switch action {
                    case .advance(let target): questionIndex = target
                    case .send: answer(.questions(answerState.answers(for: questions)))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(answerState.selectedLabels(for: questions[index]).isEmpty)
            }
            .font(typography.caption.font)
            .chatTextColumn()
        } else if !isPending {
            Text("Answered")
                .font(typography.caption.semibold)
                .emphasis(.secondary)
                .chatTextColumn()
        }
    }

    /// An answered question, once the user has moved past it: the question
    /// and what they chose, rather than the whole card of options again.
    private func answeredSummary(
        _ question: InteractiveToolPayload.AskedQuestion
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(question.question)
                .font(typography.caption.font)
                .emphasis(.secondary)
            Text(answerState.selectedLabels(for: question).joined(separator: ", "))
                .font(typography.caption.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatTextColumn()
    }

    private func pagingControls(current: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                questionIndex = QuestionPaging.previous(current)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(current == 0)
            Text("\(current + 1) of \(count)")
                .font(typography.caption.font)
                .emphasis(.subtle)
            Button {
                questionIndex = QuestionPaging.next(current, count: count)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(current == count - 1)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .chatTextColumn()
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
        .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(optionBorderColor(isSelected: isSelected), lineWidth: isSelected && isAnswerable ? 1.5 : 1)
        }
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

    private func optionBorderColor(isSelected: Bool) -> Color {
        isSelected && isAnswerable
            ? colors.selection
            : colors.divider
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
