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
