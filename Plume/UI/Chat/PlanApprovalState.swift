import Foundation

/// Where the plan stands, which is what the overlay's footer shows.
///
/// Derived from the most recent `ExitPlanMode` call and its answer, never
/// from whether a plan file exists. `TranscriptParser` records `planFilePath`
/// from a `plan_mode` line as well as `plan_mode_exit`, so a plan the agent
/// merely wrote is already on disk and already viewable — file presence says
/// nothing about whether it was ever proposed.
enum PlanApprovalState: Equatable {
    /// Proposed and waiting on the user. The footer offers the approval options.
    case awaitingDecision
    case approved
    /// Never proposed, or proposed and rejected.
    ///
    /// One state rather than two: the plan may have been rewritten since a
    /// rejection, so naming that rejection risks describing a document that no
    /// longer exists. This speaks only to what is still true.
    case notApprovedYet

    /// The answer a plan proposal came back with, as far as the footer cares.
    enum Decision: Equatable {
        case approved
        case rejected
    }

    /// A plan proposal and whatever answer it has so far.
    struct Proposal: Equatable {
        let toolUseID: String
        /// Nil while the user has not answered.
        let decision: Decision?

        init(toolUseID: String, decision: Decision? = nil) {
            self.toolUseID = toolUseID
            self.decision = decision
        }
    }

    /// - Parameter latestProposal: the most recent `ExitPlanMode` call, or nil
    ///   when the conversation has not contained one.
    static func derive(latestProposal: Proposal?) -> PlanApprovalState {
        guard let latestProposal else { return .notApprovedYet }
        switch latestProposal.decision {
        case .none: return .awaitingDecision
        case .approved: return .approved
        case .rejected: return .notApprovedYet
        }
    }

    var footerLabel: String? {
        switch self {
        case .awaitingDecision: nil
        case .approved: "Approved"
        case .notApprovedYet: "Not approved yet"
        }
    }

    var showsApprovalOptions: Bool { self == .awaitingDecision }

    /// Whether the overlay may be dismissed outright rather than only
    /// minimized. A live proposal's approval options are shown nowhere else,
    /// so closing would leave the request open on the wire with no way back
    /// to it; once answered, the overlay is just a viewer again.
    var isClosable: Bool { self != .awaitingDecision }
}

/// The one-line gist of a plan, for the inline row that stands in for it.
enum PlanSummary {
    /// The plan's first non-empty line, with any leading heading marker
    /// removed. Falls back to a fixed label rather than rendering an empty
    /// row for a plan that is all whitespace or all punctuation.
    static func firstLine(of markdown: String) -> String {
        let firstNonEmpty = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstNonEmpty else { return "Plan" }
        let unheaded = firstNonEmpty
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
        return unheaded.isEmpty ? "Plan" : unheaded
    }

    /// What the plan calls itself: its first heading, normally the top-level
    /// one it opens with. Nil when it has none — a plan file exists from the
    /// moment the agent starts writing it, so an empty or heading-less file is
    /// the ordinary early state and the caller falls back to the file name.
    static func title(of markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let afterHashes = trimmed.drop { $0 == "#" }
            // A heading needs at least one hash and a space after them, else
            // `#tag` reads as one.
            guard afterHashes.count < trimmed.count, afterHashes.first == " " else { continue }
            let text = afterHashes.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }
}
