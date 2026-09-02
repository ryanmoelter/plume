import Foundation

/// Selection state for an in-flight `AskUserQuestion`, keyed by question text.
///
/// Pure value logic so the view stays a renderer: the view holds one of these
/// in `@State`, toggles options through it, and reads `isComplete` to decide
/// whether submitting is allowed.
struct PermissionAnswerState: Equatable {
    /// Question text -> chosen option labels, in the order they were picked.
    private(set) var selections: [String: [String]] = [:]

    init() {}

    func selectedLabels(for question: InteractiveToolPayload.AskedQuestion) -> [String] {
        selections[question.question] ?? []
    }

    func isSelected(_ label: String, for question: InteractiveToolPayload.AskedQuestion) -> Bool {
        selectedLabels(for: question).contains(label)
    }

    /// Single-select replaces; multi-select toggles.
    mutating func toggle(_ label: String, for question: InteractiveToolPayload.AskedQuestion) {
        guard question.multiSelect else {
            selections[question.question] = [label]
            return
        }
        var labels = selectedLabels(for: question)
        if let index = labels.firstIndex(of: label) {
            labels.remove(at: index)
        } else {
            labels.append(label)
        }
        selections[question.question] = labels.isEmpty ? nil : labels
    }

    func isComplete(for questions: [InteractiveToolPayload.AskedQuestion]) -> Bool {
        questions.allSatisfy { !selectedLabels(for: $0).isEmpty }
    }

    /// The wire shape: question text -> comma-separated option labels.
    func answers(for questions: [InteractiveToolPayload.AskedQuestion]) -> [String: String] {
        var answers: [String: String] = [:]
        for question in questions {
            let labels = selectedLabels(for: question)
            guard !labels.isEmpty else { continue }
            answers[question.question] = labels.joined(separator: ", ")
        }
        return answers
    }
}
