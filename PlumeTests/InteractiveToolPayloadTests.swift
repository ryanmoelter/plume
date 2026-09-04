import Testing
import Foundation
@testable import Plume

/// Fixtures mirror real `tool_use` inputs from `~/.claude/projects`.
struct InteractiveToolPayloadTests {
    private func input(_ json: String) -> [String: JSONValue] {
        let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        return decoded ?? [:]
    }

    @Test func aPlanDecodesItsMarkdownAndPath() {
        let payload = InteractiveToolPayload.decoding(
            name: "ExitPlanMode",
            input: input("{\"plan\":\"# Title\\n\\nBody\",\"planFilePath\":\"/tmp/plans/a.md\"}")
        )
        #expect(payload == .plan(markdown: "# Title\n\nBody", filePath: "/tmp/plans/a.md"))
    }

    @Test func aPlanWithoutAPathStillDecodes() {
        let payload = InteractiveToolPayload.decoding(name: "ExitPlanMode", input: input(#"{"plan":"just markdown"}"#))
        #expect(payload == .plan(markdown: "just markdown", filePath: nil))
    }

    /// One real `ExitPlanMode` in the corpus carries an empty input. It must
    /// fall back to the ordinary JSON rendering rather than an empty panel.
    @Test func anEmptyPlanFallsBackToJSON() {
        #expect(InteractiveToolPayload.decoding(name: "ExitPlanMode", input: input("{}")) == nil)
        #expect(InteractiveToolPayload.decoding(name: "ExitPlanMode", input: input(#"{"plan":"   "}"#)) == nil)
    }

    @Test func aQuestionDecodesItsOptions() {
        let payload = InteractiveToolPayload.decoding(
            name: "AskUserQuestion",
            input: input(#"""
            {"questions":[{"header":"Intent","question":"What do you want?","multiSelect":false,
            "options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}
            """#)
        )

        guard case .questions(let questions)? = payload else {
            Issue.record("expected questions")
            return
        }
        #expect(questions.count == 1)
        #expect(questions[0].header == "Intent")
        #expect(questions[0].question == "What do you want?")
        #expect(questions[0].multiSelect == false)
        #expect(questions[0].options.map(\.label) == ["A", "B"])
        #expect(questions[0].options[1].description == "second")
    }

    @Test func multiSelectIsCarried() {
        let payload = InteractiveToolPayload.decoding(
            name: "AskUserQuestion",
            input: input(#"{"questions":[{"question":"Pick","multiSelect":true,"options":[{"label":"A"}]}]}"#)
        )
        guard case .questions(let questions)? = payload else {
            Issue.record("expected questions")
            return
        }
        #expect(questions[0].multiSelect)
        // An option with no description is still an option.
        #expect(questions[0].options[0].description.isEmpty)
    }

    @Test func aQuestionMissingItsTextIsDropped() {
        #expect(
            InteractiveToolPayload.decoding(
                name: "AskUserQuestion",
                input: input(#"{"questions":[{"header":"only a header"}]}"#)
            ) == nil
        )
    }

    @Test func anEmptyQuestionListFallsBackToJSON() {
        #expect(InteractiveToolPayload.decoding(name: "AskUserQuestion", input: input(#"{"questions":[]}"#)) == nil)
        #expect(InteractiveToolPayload.decoding(name: "AskUserQuestion", input: input("{}")) == nil)
    }

    /// Real shape from `~/.claude/projects`: `"question"="answer"` pairs
    /// joined by `, `, wrapped in a fixed sentence.
    @Test func answersAreRecoveredFromTheToolResultText() {
        let questions = [
            InteractiveToolPayload.AskedQuestion(
                header: "Scope", question: "How much of the release process do you want set up?",
                multiSelect: false, options: []
            ),
            InteractiveToolPayload.AskedQuestion(
                header: "Target IDE", question: "Which platform should the published plugin target?",
                multiSelect: false, options: []
            )
        ]
        let resultText = #"""
        Your questions have been answered: "How much of the release process do you want set up?"="Full release automation", "Which platform should the published plugin target?"="Both". You can now continue with these answers in mind.
        """#

        let answers = InteractiveToolPayload.answers(from: resultText, for: questions)

        #expect(answers["How much of the release process do you want set up?"] == "Full release automation")
        #expect(answers["Which platform should the published plugin target?"] == "Both")
    }

    /// A multi-select answer's "selected preview" annotation trails the value
    /// with no closing quote of its own — the parser must stop at the marker
    /// rather than reading into the preview body.
    @Test func aSelectedPreviewAnnotationDoesNotLeakIntoTheAnswer() {
        let questions = [
            InteractiveToolPayload.AskedQuestion(
                header: "", question: "Which slice should I plan?", multiSelect: true, options: []
            )
        ]
        let resultText = #"""
        Your questions have been answered: "Which slice should I plan?"="Notify on agent needs-input (Recommended)" selected preview:\#nSection "Notifications"\#n  [ toggle ]. You can now continue with these answers in mind.
        """#

        let answers = InteractiveToolPayload.answers(from: resultText, for: questions)

        #expect(answers["Which slice should I plan?"] == "Notify on agent needs-input (Recommended)")
    }

    /// A question with no matching answer in the text — dismissed, or the
    /// text doesn't match at all — degrades to nothing rather than a bogus
    /// or crashing lookup.
    @Test func aQuestionWithNoRecordedAnswerIsOmitted() {
        let questions = [
            InteractiveToolPayload.AskedQuestion(header: "", question: "Pick one", multiSelect: false, options: [])
        ]
        #expect(InteractiveToolPayload.answers(from: "not a recognized shape at all", for: questions).isEmpty)
        #expect(InteractiveToolPayload.answers(from: "", for: questions).isEmpty)
    }

    @Test func everyOtherToolHasNoInteractivePayload() {
        #expect(InteractiveToolPayload.decoding(name: "Bash", input: input(#"{"command":"ls"}"#)) == nil)
        #expect(InteractiveToolPayload.decoding(name: "Read", input: input(#"{"plan":"decoy"}"#)) == nil)
    }

    @Test func theParserAttachesThePayloadToTheCall() {
        let line = #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"ExitPlanMode","input":{"plan":"a plan","planFilePath":"/tmp/p.md"}}]}}"#
        let transcript = TranscriptParser.parse(Data(line.utf8))

        guard case .toolCall(let call)? = transcript.messages.first?.blocks.first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.interactive == .plan(markdown: "a plan", filePath: "/tmp/p.md"))
    }

    @Test func anOrdinaryCallKeepsANilPayload() {
        let line = #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
        let transcript = TranscriptParser.parse(Data(line.utf8))

        guard case .toolCall(let call)? = transcript.messages.first?.blocks.first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.interactive == nil)
    }
}
