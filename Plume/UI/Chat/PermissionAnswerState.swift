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

/// Reads a settled `ExitPlanMode` tool result — the denial message text, when
/// there is one — into what the transcript row should say.
///
/// Pure so the parsing rule is testable without a SwiftUI host: an approval
/// and a rejection both come back as a `ToolCall.result` string, with nothing
/// structural to tell them apart (the transcript records only text, and a
/// user's own rejection reason can be anything). `PendingPermissionDock`
/// marks every denial with `rejectionPrefix` for exactly this reason — it is
/// the one thing common to every rejection and no approval.
enum PlanResolution {
    /// The fixed marker every denial message starts with, so a rejection is
    /// recognizable regardless of what the user typed as their reason.
    private static let rejectionPrefix = "Rejected:"

    /// The model-facing tool result for a rejection. `PendingPermissionDock`
    /// builds every denial through this, so `isRejection`/`rejectionReason`
    /// below have exactly one wire format to read back.
    static func denialMessage(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rejectionPrefix }
        return "\(rejectionPrefix) \(trimmed)"
    }

    /// Whether `resultText` reads as a rejection rather than an approval.
    static func isRejection(_ resultText: String) -> Bool {
        resultText.hasPrefix(rejectionPrefix)
    }

    /// The user's own reason, or nil when they left it blank.
    static func rejectionReason(from resultText: String) -> String? {
        guard isRejection(resultText) else { return nil }
        let remainder = resultText
            .dropFirst(rejectionPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? nil : remainder
    }
}

/// Index arithmetic for paging through a fixed list one at a time, clamped
/// rather than wrapping — a plain "prev/next" reads as movement through a
/// list, not a carousel that loops back on itself.
enum QuestionPaging {
    /// `current` moved back one, held at the first index.
    static func previous(_ current: Int) -> Int {
        max(0, current - 1)
    }

    /// `current` moved forward one, held at the last valid index for `count`.
    ///
    /// `count == 0` has no valid index at all; clamping to 0 there is an
    /// arbitrary but harmless choice since nothing renders for an empty list.
    static func next(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, current + 1)
    }

    /// `current` re-clamped after `count` changes, so a stale index from a
    /// previous (larger) question set never reads out of bounds.
    static func clamped(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, current), count - 1)
    }

    /// The first question with no answer yet, or nil once every one is
    /// answered. Drives what the primary button does: move to the question
    /// still waiting, or send.
    static func firstUnanswered(
        _ questions: [InteractiveToolPayload.AskedQuestion],
        in state: PermissionAnswerState
    ) -> Int? {
        questions.firstIndex { state.selectedLabels(for: $0).isEmpty }
    }
}

/// What the question card's primary button does right now.
///
/// One button rather than paging arrows plus a send: answering a question
/// should carry the user forward on its own, and the arrows exist only to go
/// back over something already answered.
enum QuestionPrimaryAction: Equatable {
    /// Move to the question at this index, which is still unanswered.
    case advance(to: Int)
    case send

    static func next(
        for questions: [InteractiveToolPayload.AskedQuestion],
        in state: PermissionAnswerState
    ) -> QuestionPrimaryAction {
        guard let unanswered = QuestionPaging.firstUnanswered(questions, in: state) else {
            return .send
        }
        return .advance(to: unanswered)
    }

    var label: String {
        switch self {
        case .advance: "Next question"
        case .send: "Send answer"
        }
    }
}
