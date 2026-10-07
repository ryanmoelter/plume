import CoreGraphics
import Foundation

enum InfoPanePresentation: String, CaseIterable {
    /// A glass box at the chat's top-trailing corner.
    case side
    /// A block after the last message, folding behind the composer.
    case inline

    var label: String {
        switch self {
        case .side: "Side Pane"
        case .inline: "Inline"
        }
    }
}

enum InfoPaneState: String {
    case expanded
    /// Icons only, expanding while hovered.
    case collapsed
    case hidden
}

/// Everything the info pane shows for one chat tab, resolved from the stores
/// by `ChatTabView` so the views below it read a plain value.
///
/// Equatable because the inline presentation rides in `ChatListInputs`, which
/// rebuilds an item only when its inputs change.
struct InfoPaneFacts: Equatable {
    struct Branch: Equatable {
        let name: String
        let isWorktree: Bool
        let ahead: Int?
        let behind: Int?
        let isDirty: Bool
    }

    struct PullRequestFacts: Equatable {
        let state: PullRequestFetchState
        /// Resolved by the store, so the repository's ignored checks are
        /// already suppressed. Nil when the state holds no pull request.
        let checkRollup: CheckRollup?
    }

    var tabID: UUID
    var liveSubagents: [SubagentTranscript] = []
    /// Empty when the user has chosen not to see them.
    var completedSubagents: [SubagentTranscript] = []
    var backgroundTasks: [BackgroundTaskTracker.Entry] = []
    /// What the plan row reads, or nil when the conversation has no plan.
    var planTitle: String?
    var folder: String?
    var branch: Branch?
    /// Nil when PR status is turned off or the forge cannot answer.
    var pullRequest: PullRequestFacts?

    var sections: [InfoPaneSection] {
        var sections: [InfoPaneSection] = []
        if !liveSubagents.isEmpty || !completedSubagents.isEmpty { sections.append(.subagents) }
        if !backgroundTasks.isEmpty { sections.append(.backgroundTasks) }
        if planTitle != nil { sections.append(.plan) }
        if folder != nil { sections.append(.folder) }
        if branch != nil { sections.append(.branch) }
        if pullRequest != nil { sections.append(.pullRequest) }
        return sections
    }
}

extension InfoPaneFacts {
    /// Splits subagents the way the sidebar does: one still inside its linger
    /// counts as live.
    static func splitSubagents(
        _ subagents: [SubagentTranscript],
        showsCompleted: Bool,
        hasSettled: (SubagentTranscript) -> Bool
    ) -> (live: [SubagentTranscript], completed: [SubagentTranscript]) {
        let live = subagents.filter { !hasSettled($0) }
        let completed = showsCompleted ? subagents.filter(hasSettled) : []
        return (live, completed)
    }

    /// A state with nothing to say about a pull request is left out, rather
    /// than drawn as an empty row.
    static func pullRequest(
        state: PullRequestFetchState?,
        checkRollup: (PullRequest) -> CheckRollup
    ) -> PullRequestFacts? {
        guard let state else { return nil }
        switch state {
        case .forgeUnsupported:
            return nil
        case .pullRequest(let pullRequest):
            return PullRequestFacts(state: state, checkRollup: checkRollup(pullRequest))
        default:
            return PullRequestFacts(state: state, checkRollup: nil)
        }
    }
}

enum InfoPaneSection: Equatable {
    case subagents
    case backgroundTasks
    case plan
    case folder
    case branch
    case pullRequest
}

enum InfoPaneLayout {
    static let paneWidth: CGFloat = 280
    static let iconColumnContentWidth: CGFloat = 20

    /// The narrowest the chat column may get with the pane beside it, as a
    /// share of the prose column it would otherwise have. Below that the pane
    /// floats instead, so opening it never squeezes the conversation.
    static let minimumChatShare: CGFloat = 0.75

    static func fitsBeside(width: CGFloat, contentWidth: CGFloat, inset: CGFloat) -> Bool {
        width - paneWidth - inset >= contentWidth * minimumChatShare
    }
}
