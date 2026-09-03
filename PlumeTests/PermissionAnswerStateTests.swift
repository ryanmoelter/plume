import Testing
@testable import Plume

@MainActor
struct PermissionAnswerStateTests {
    private func question(
        _ text: String,
        multiSelect: Bool = false,
        options: [String] = ["A", "B", "C"]
    ) -> InteractiveToolPayload.AskedQuestion {
        InteractiveToolPayload.AskedQuestion(
            header: "",
            question: text,
            multiSelect: multiSelect,
            options: options.map { .init(label: $0, description: "") }
        )
    }

    @Test func singleSelectReplacesTheChoice() {
        let question = question("Pick one")
        var state = PermissionAnswerState()
        state.toggle("A", for: question)
        state.toggle("B", for: question)
        #expect(state.selectedLabels(for: question) == ["B"])
    }

    @Test func multiSelectAccumulatesAndTogglesOff() {
        let question = question("Pick any", multiSelect: true)
        var state = PermissionAnswerState()
        state.toggle("A", for: question)
        state.toggle("C", for: question)
        #expect(state.selectedLabels(for: question) == ["A", "C"])
        state.toggle("A", for: question)
        #expect(state.selectedLabels(for: question) == ["C"])
    }

    @Test func everyQuestionMustBeAnsweredBeforeSubmitting() {
        let questions = [question("First"), question("Second")]
        var state = PermissionAnswerState()
        #expect(!state.isComplete(for: questions))
        state.toggle("A", for: questions[0])
        #expect(!state.isComplete(for: questions))
        state.toggle("B", for: questions[1])
        #expect(state.isComplete(for: questions))
    }

    @Test func answersMapQuestionTextToCommaSeparatedLabels() {
        let single = question("Single")
        let multi = question("Multi", multiSelect: true)
        var state = PermissionAnswerState()
        state.toggle("A", for: single)
        state.toggle("B", for: multi)
        state.toggle("C", for: multi)
        #expect(state.answers(for: [single, multi]) == ["Single": "A", "Multi": "B, C"])
    }

    @Test func unansweredQuestionsAreOmittedFromTheAnswers() {
        let answered = question("Answered")
        var state = PermissionAnswerState()
        state.toggle("A", for: answered)
        #expect(state.answers(for: [answered, question("Skipped")]) == ["Answered": "A"])
    }
}

struct PlanResolutionTests {
    @Test func aBlankReasonBuildsJustThePrefix() {
        let message = PlanResolution.denialMessage(reason: "  ")
        #expect(PlanResolution.isRejection(message))
        #expect(PlanResolution.rejectionReason(from: message) == nil)
    }

    @Test func aTypedReasonRoundTripsThroughTheBuiltMessage() {
        let message = PlanResolution.denialMessage(reason: "Too broad, scope it down")
        #expect(PlanResolution.isRejection(message))
        #expect(PlanResolution.rejectionReason(from: message) == "Too broad, scope it down")
    }

    /// A user's own reason is free text, so it can read like an approval
    /// ("looks good, but...") without the shared prefix to key off.
    @Test func aReasonThatSoundsLikeApprovalStillReadsAsARejection() {
        let message = PlanResolution.denialMessage(reason: "Looks good, but hold off for now")
        #expect(PlanResolution.isRejection(message))
        #expect(PlanResolution.rejectionReason(from: message) == "Looks good, but hold off for now")
    }

    @Test func anApprovalResultIsNotARejection() {
        #expect(!PlanResolution.isRejection("Plan approved. Continuing."))
    }
}

struct QuestionPagingTests {
    @Test func previousStopsAtZero() {
        #expect(QuestionPaging.previous(2) == 1)
        #expect(QuestionPaging.previous(1) == 0)
        #expect(QuestionPaging.previous(0) == 0)
    }

    @Test func nextStopsAtTheLastIndex() {
        #expect(QuestionPaging.next(0, count: 3) == 1)
        #expect(QuestionPaging.next(1, count: 3) == 2)
        #expect(QuestionPaging.next(2, count: 3) == 2)
    }

    @Test func nextWithNoQuestionsStaysAtZero() {
        #expect(QuestionPaging.next(0, count: 0) == 0)
    }

    @Test func clampedPullsAnOutOfRangeIndexIntoBounds() {
        #expect(QuestionPaging.clamped(5, count: 3) == 2)
        #expect(QuestionPaging.clamped(-1, count: 3) == 0)
        #expect(QuestionPaging.clamped(1, count: 3) == 1)
    }

    @Test func clampedWithNoQuestionsIsZero() {
        #expect(QuestionPaging.clamped(4, count: 0) == 0)
    }
}

@MainActor
struct PermissionInputDetailsTests {
    @Test func theMostRelevantFieldsComeFirst() {
        let fields = PermissionInputDetails.fields(for: [
            "timeout": .number(120),
            "command": .string("ls -la"),
            "description": .string("List files")
        ])
        #expect(fields.map(\.key) == ["command", "description", "timeout"])
    }

    @Test func codeFieldsAreMarkedForMonospacing() {
        let fields = PermissionInputDetails.fields(for: [
            "file_path": .string("/tmp/x.txt"),
            "description": .string("Write it")
        ])
        #expect(fields.first(where: { $0.key == "file_path" })?.isCode == true)
        #expect(fields.first(where: { $0.key == "description" })?.isCode == false)
    }

    @Test func emptyAndNullValuesAreDropped() {
        let fields = PermissionInputDetails.fields(for: [
            "command": .string("echo hi"),
            "blank": .string(""),
            "missing": .null
        ])
        #expect(fields.map(\.key) == ["command"])
    }

    @Test func wholeNumbersLoseTheirDecimalPoint() {
        let fields = PermissionInputDetails.fields(for: ["limit": .number(20)])
        #expect(fields.first?.value == "20")
    }
}

/// The one button that carries the user through a multi-question card:
/// forward while anything is unanswered, send once nothing is.
@MainActor
struct QuestionPrimaryActionTests {
    private func question(_ text: String) -> InteractiveToolPayload.AskedQuestion {
        InteractiveToolPayload.AskedQuestion(
            header: "",
            question: text,
            multiSelect: false,
            options: [.init(label: "A", description: ""), .init(label: "B", description: "")]
        )
    }

    @Test func advancesToTheFirstUnansweredQuestion() {
        let questions = [question("One"), question("Two"), question("Three")]
        var state = PermissionAnswerState()
        state.toggle("A", for: questions[0])

        #expect(QuestionPrimaryAction.next(for: questions, in: state) == .advance(to: 1))
    }

    /// Answering out of order sends the user back to the gap, not onward past
    /// it — otherwise paging could leave a question silently unanswered.
    @Test func advancesBackwardToAGapLeftEarlier() {
        let questions = [question("One"), question("Two")]
        var state = PermissionAnswerState()
        state.toggle("A", for: questions[1])

        #expect(QuestionPrimaryAction.next(for: questions, in: state) == .advance(to: 0))
    }

    @Test func sendsOnceEveryQuestionIsAnswered() {
        let questions = [question("One"), question("Two")]
        var state = PermissionAnswerState()
        state.toggle("A", for: questions[0])
        state.toggle("B", for: questions[1])

        #expect(QuestionPrimaryAction.next(for: questions, in: state) == .send)
    }

    @Test func theLabelSaysWhichActionItIs() {
        #expect(QuestionPrimaryAction.advance(to: 2).label == "Next question")
        #expect(QuestionPrimaryAction.send.label == "Send answer")
    }

    @Test func aSingleAnsweredQuestionSendsRatherThanAdvancing() {
        let questions = [question("Only")]
        var state = PermissionAnswerState()
        state.toggle("A", for: questions[0])

        #expect(QuestionPrimaryAction.next(for: questions, in: state) == .send)
    }
}
