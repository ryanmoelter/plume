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
        VStack(alignment: .leading, spacing: DecisionCard.sectionSpacing) {
            switch payload {
            case .plan(let markdown, let filePath):
                planBody(markdown: markdown, filePath: filePath)
            case .questions(let questions):
                questionsBody(questions)
            }
        }
        .decisionCard(subject: isPending ? subject : nil, colors: colors)
    }

    // MARK: - Plan

    /// A summary, not the plan itself. The overlay renders the document and
    /// owns the decision, so repeating either here would ask the user to read
    /// the same plan twice and choose in two places.
    @ViewBuilder
    private func planBody(markdown: String, filePath: String?) -> some View {
        header(symbol: StatusSymbol.plan.name, title: "Proposed plan")
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

    /// One question at a time while answering, and the whole set as a compact
    /// summary once it is settled. Showing every question alongside the one
    /// being answered buries it; showing the option cards again afterwards
    /// re-asks a question that already has an answer.
    @ViewBuilder
    private func questionsBody(_ questions: [InteractiveToolPayload.AskedQuestion]) -> some View {
        header(symbol: StatusSymbol.question.name, title: questions.count == 1 ? "Question" : "Questions")
        if let answer {
            askingBody(questions, answer: answer)
        } else {
            answeredBody(questions)
        }
    }

    @ViewBuilder
    private func askingBody(
        _ questions: [InteractiveToolPayload.AskedQuestion],
        answer: @escaping (Answer) -> Void
    ) -> some View {
        let index = QuestionPaging.clamped(questionIndex, count: questions.count)
        if questions.indices.contains(index) {
            let question = questions[index]
            if questions.count > 1 {
                pagingControls(current: index, count: questions.count)
            }
            VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
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
                freeTextRow(for: question)
            }
            let action = QuestionPrimaryAction.next(for: questions, in: answerState)
            HStack {
                Spacer()
                Button(action.label) {
                    switch action {
                    case .advance(let target): questionIndex = target
                    case .send: answer(.questions(answerState.answers(for: questions)))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!answerState.isComplete(for: [question]))
            }
            .font(typography.caption.font)
            .chatTextColumn()
        }
    }

    /// Every question and what was chosen, one pair each.
    ///
    /// A row still mounted from the live answering session has its choices in
    /// `answerState`; a row rebuilt from the transcript reads them back out of
    /// the settled call's tool result, the only place they survive a reload.
    @ViewBuilder
    private func answeredBody(_ questions: [InteractiveToolPayload.AskedQuestion]) -> some View {
        let recordedAnswers = resultText.map { InteractiveToolPayload.answers(from: $0, for: questions) } ?? [:]
        VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.question)
                        .font(typography.caption.font)
                        .emphasis(.secondary)
                    let liveChosen = answerState.selectedLabels(for: question)
                    let liveTyped = answerState.freeText(for: question)
                    if !liveChosen.isEmpty {
                        Text(liveChosen.joined(separator: ", "))
                            .font(typography.caption.semibold)
                    } else if !liveTyped.isEmpty {
                        Text(liveTyped)
                            .font(typography.caption.semibold)
                    } else if let recorded = recordedAnswers[question.question] {
                        Text(recorded)
                            .font(typography.caption.semibold)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .chatTextColumn()
    }

    private func pagingControls(current: Int, count: Int) -> some View {
        HStack(spacing: DecisionCard.nestedPadding) {
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
        .decisionField(isFilled: isSelected && isAnswerable, colors: colors)
        .contentShape(.rect)
        .chatTextColumn()

        if isAnswerable {
            Button {
                answerState.toggle(option.label, for: question)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.questionOption, label: option.label)
            .accessibilityLabel(option.label)
        } else {
            content
        }
    }

    /// A typed answer, styled as one more way to answer rather than a
    /// separate control below the options.
    @ViewBuilder
    private func freeTextRow(for question: InteractiveToolPayload.AskedQuestion) -> some View {
        if isAnswerable {
            TextField("Or type your own answer…", text: Binding(
                get: { answerState.freeText(for: question) },
                set: { answerState.setFreeText($0, for: question) }
            ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(typography.body.medium)
                .decisionField(
                    isFilled: !answerState.freeText(for: question).isEmpty,
                    colors: colors
                )
                .chatTextColumn()
                .plumeID(
                    AccessibilityID.questionFreeTextField,
                    value: answerState.freeText(for: question),
                    setValue: { answerState.setFreeText($0, for: question) }
                )
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

    // MARK: - Chrome

    private func header(symbol: String, title: String) -> some View {
        DecisionCardHeader(
            title: title,
            symbol: symbol,
            subject: isPending ? subject : nil
        )
    }

    /// A question only waits on the user; approving a plan sets work going.
    private var subject: DecisionSubject {
        switch payload {
        case .questions: .inquiry
        case .plan: .consequential
        }
    }
}
