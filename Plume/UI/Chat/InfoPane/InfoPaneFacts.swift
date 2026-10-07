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
    /// One row of icons; the side pane opens over the chat while hovered.
    case collapsed

    /// A pane once hidden comes back collapsed, the closest state left.
    init?(rawValue: String) {
        switch rawValue {
        case "expanded": self = .expanded
        case "collapsed", "hidden": self = .collapsed
        default: return nil
        }
    }

    var toggled: InfoPaneState {
        self == .expanded ? .collapsed : .expanded
    }
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
        /// Nil until the store has resolved the repository's origin.
        var forge: ForgeKind? = nil

        var hasPullRequest: Bool {
            if case .pullRequest = state { true } else { false }
        }
    }

    var tabID: UUID
    var liveSubagents: [SubagentTranscript] = []
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

    /// What the collapsed form draws an icon for: only what has something to
    /// say. Where the conversation runs rarely changes, and a branch without
    /// a pull request has no status worth a glance.
    var collapsedSections: [InfoPaneSection] {
        sections.filter { section in
            switch section {
            case .subagents: !liveSubagents.isEmpty
            case .pullRequest: pullRequest?.hasPullRequest == true
            case .folder, .branch: false
            case .backgroundTasks, .plan: true
            }
        }
    }
}

extension InfoPaneFacts {
    /// Splits subagents the way the sidebar does: one still inside its linger
    /// counts as live.
    static func splitSubagents(
        _ subagents: [SubagentTranscript],
        hasSettled: (SubagentTranscript) -> Bool
    ) -> (live: [SubagentTranscript], completed: [SubagentTranscript]) {
        (subagents.filter { !hasSettled($0) }, subagents.filter(hasSettled))
    }

    /// A state with nothing to say about a pull request is left out, rather
    /// than drawn as an empty row.
    static func pullRequest(
        state: PullRequestFetchState?,
        forge: ForgeKind? = nil,
        checkRollup: (PullRequest) -> CheckRollup
    ) -> PullRequestFacts? {
        guard let state else { return nil }
        switch state {
        case .forgeUnsupported:
            return nil
        case .pullRequest(let pullRequest):
            return PullRequestFacts(state: state, checkRollup: checkRollup(pullRequest), forge: forge)
        default:
            return PullRequestFacts(state: state, checkRollup: nil, forge: forge)
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
    /// The shared width every row's icon centers in, so the text beside the
    /// icons starts on one edge.
    static let iconColumnWidth: CGFloat = 16
    static let columnSpacing: CGFloat = 6

    /// The room a pinned pane takes from the chat's trailing edge: the pane,
    /// and the gap and minimap rail beyond it. The chat's own edge padding
    /// is the gap on the pane's other side.
    static func reservedWidth(railFootprint: CGFloat, gap: CGFloat) -> CGFloat {
        paneWidth + gap + railFootprint
    }

    /// Pinned beside the chat only while the chat keeps its full prose
    /// column, edge padding included. Narrower than that the pane opens over
    /// the chat on demand instead.
    static func fitsBeside(width: CGFloat, reservedWidth: CGFloat, chatColumnWidth: CGFloat) -> Bool {
        width - reservedWidth >= chatColumnWidth
    }

    /// Where the side pane sits over a chat `width` wide, and what room the
    /// chat gives it.
    static func side(
        width: CGFloat,
        railFootprint: CGFloat,
        gap: CGFloat,
        chatColumnWidth: CGFloat,
        state: InfoPaneState,
        collapsedHeight: CGFloat
    ) -> SideGeometry {
        let reserved = reservedWidth(railFootprint: railFootprint, gap: gap)
        let fits = fitsBeside(width: width, reservedWidth: reserved, chatColumnWidth: chatColumnWidth)
        let isPinned = fits && state == .expanded
        return SideGeometry(
            fitsBeside: fits,
            isPinned: isPinned,
            trailingInset: railFootprint + gap,
            chatTrailingReserve: isPinned ? reserved : 0,
            chatTopInset: isPinned ? 0 : collapsedHeight + gap
        )
    }

    struct SideGeometry: Equatable {
        var fitsBeside: Bool
        /// Open beside the chat rather than over it.
        var isPinned: Bool
        /// From the chat's trailing edge to the pane's, clear of the minimap.
        var trailingInset: CGFloat
        /// Taken off the chat's trailing edge, so its columns center in what
        /// is left.
        var chatTrailingReserve: CGFloat
        /// Added above the first message, so the collapsed pane never covers
        /// it at rest.
        var chatTopInset: CGFloat
    }
}
