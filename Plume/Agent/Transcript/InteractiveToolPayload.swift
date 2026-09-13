import Foundation

/// The two tools that talk to the user, decoded from a `tool_use` input so
/// the chat can draw them as themselves rather than as pretty-printed JSON.
///
/// Read-only. Both payloads carry everything a real rendering needs, but
/// *answering* one means sending a structured response, and the composer's
/// send path is a paste into the terminal — it cannot pick the third option
/// of a running prompt. See `docs/agent-transport.md`.
nonisolated enum InteractiveToolPayload: Equatable {
    case plan(markdown: String, filePath: String?)
    case questions([AskedQuestion])

    /// One question from an `AskUserQuestion` call.
    struct AskedQuestion: Equatable, Identifiable {
        let header: String
        let question: String
        let multiSelect: Bool
        let options: [Option]

        var id: String { header + question }

        struct Option: Equatable, Identifiable {
            let label: String
            let description: String

            var id: String { label }
        }
    }

    /// Decodes a payload for a tool that has one, or nil for every other tool.
    ///
    /// A malformed or empty payload also returns nil, so the call falls back
    /// to the ordinary JSON rendering rather than showing an empty panel —
    /// one real `ExitPlanMode` in the corpus carries no `plan` at all.
    static func decoding(name: String, input: [String: JSONValue]) -> InteractiveToolPayload? {
        switch name {
        case "ExitPlanMode":
            guard let markdown = input["plan"]?.stringValue,
                  !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .plan(markdown: markdown, filePath: input["planFilePath"]?.stringValue)

        case "AskUserQuestion":
            guard case .array(let raw)? = input["questions"] else { return nil }
            let questions = raw.compactMap(askedQuestion(from:))
            return questions.isEmpty ? nil : .questions(questions)

        default:
            return nil
        }
    }

    /// Recovers what was chosen for each question from the tool result's
    /// plain-text summary — the only place a settled call still carries the
    /// answers, since `updatedInput` reaches the model but never lands back
    /// in the transcript's `tool_use.input`.
    ///
    /// The text is fixed-format but not machine-generated JSON: `"question
    /// text"="chosen labels"` pairs joined by `, `, wrapped in a sentence
    /// whose wording changes over time, and a multi-select answer can carry
    /// a `selected preview:` annotation after its value with no closing
    /// quote of its own. This anchors on each known question's exact text
    /// and reads the answer up to whichever comes first: the `selected
    /// preview:` marker, or — for every question but the last — the next
    /// question's own anchor, the only marker safe against an answer
    /// containing `". ` or `", "`. The last question has no next anchor, so
    /// it stops at its closing quote followed by `. ` instead.
    static func answers(from resultText: String, for questions: [AskedQuestion]) -> [String: String] {
        var answers: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            let anchor = "\"\(question.question)\"="
            guard let anchorRange = resultText.range(of: anchor) else { continue }
            let afterAnchor = resultText[anchorRange.upperBound...]
            guard afterAnchor.hasPrefix("\"") else { continue }
            let valueStart = afterAnchor.index(after: afterAnchor.startIndex)

            var stopMarkers = [" selected preview:"]
            if index + 1 < questions.count {
                stopMarkers.append("\", \"\(questions[index + 1].question)\"=")
            } else {
                stopMarkers.append("\". ")
            }

            var valueEnd = afterAnchor.endIndex
            for marker in stopMarkers {
                if let range = afterAnchor.range(of: marker), range.lowerBound < valueEnd {
                    valueEnd = range.lowerBound
                }
            }
            guard valueStart < valueEnd else { continue }

            var value = String(afterAnchor[valueStart..<valueEnd])
            if value.hasSuffix("\"") { value.removeLast() }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            answers[question.question] = value
        }
        return answers
    }

    private static func askedQuestion(from value: JSONValue) -> AskedQuestion? {
        guard case .object(let fields) = value,
              let question = fields["question"]?.stringValue
        else { return nil }

        var options: [AskedQuestion.Option] = []
        if case .array(let rawOptions)? = fields["options"] {
            options = rawOptions.compactMap { option in
                guard case .object(let fields) = option,
                      let label = fields["label"]?.stringValue
                else { return nil }
                return AskedQuestion.Option(
                    label: label,
                    description: fields["description"]?.stringValue ?? ""
                )
            }
        }

        var multiSelect = false
        if case .bool(let flag)? = fields["multiSelect"] { multiSelect = flag }

        return AskedQuestion(
            header: fields["header"]?.stringValue ?? "",
            question: question,
            multiSelect: multiSelect,
            options: options
        )
    }
}
