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
