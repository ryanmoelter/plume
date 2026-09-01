import Foundation

/// The two tools that talk to the user, decoded from a `tool_use` input so
/// the chat can draw them as themselves rather than as pretty-printed JSON.
///
/// Read-only. Both payloads carry everything a real rendering needs, but
/// *answering* one means sending a structured response, and the composer's
/// send path is a paste into the terminal — it cannot pick the third option
/// of a running prompt. See `docs/agent-transport.md`.
enum InteractiveToolPayload: Equatable {
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
