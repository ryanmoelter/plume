import CoreGraphics
import Foundation
import SwiftUI

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

        var url: URL? {
            guard case .pullRequest(let pullRequest) = state else { return nil }
            return pullRequest.url.flatMap(URL.init(string:))
        }
    }

    /// One linked Linear issue, flattened for drawing.
    struct LinearIssueFacts: Equatable, Identifiable {
        let identifier: String
        let role: LinearLinkRole
        var title: String?
        var stateName: String?
        var stateType: LinearStateType?
        var stateColor: String?
        var assignee: String?
        var url: URL?
        /// Who touched the issue, when a subagent did.
        var attribution: String?
        /// Why a working issue is linked.
        var sourceHint: String?
        /// Set when the state has no issue to show; nil when one is drawn.
        var statusWord: String?

        var id: String { identifier }
    }

    /// Nil when Linear is off or no workspace is connected. An empty list
    /// still shows the section, for its link field.
    struct LinearFacts: Equatable {
        var issues: [LinearIssueFacts]

        var working: [LinearIssueFacts] { issues.filter { $0.role == .working } }
        var mentioned: [LinearIssueFacts] { issues.filter { $0.role == .mentioned } }
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
    var linear: LinearFacts?
    /// How many `/btw` questions this tab has asked.
    var sideChatCount = 0
    var artifacts: [ConversationArtifact] = []

    var sections: [InfoPaneSection] {
        var sections: [InfoPaneSection] = []
        if !liveSubagents.isEmpty || !completedSubagents.isEmpty { sections.append(.subagents) }
        if !backgroundTasks.isEmpty { sections.append(.backgroundTasks) }
        if pullRequest?.hasPullRequest == true { sections.append(.pullRequest) }
        if linear != nil { sections.append(.linearIssues) }
        if planTitle != nil { sections.append(.plan) }
        if !artifacts.isEmpty { sections.append(.artifacts) }
        if sideChatCount > 0 { sections.append(.sideChat) }
        if folder != nil { sections.append(.folder) }
        if branch != nil { sections.append(.branch) }
        return sections
    }

    /// What the collapsed form draws an icon for. Where the conversation runs
    /// rarely changes, so the row only marks a worktree.
    var collapsedSections: [InfoPaneSection] {
        sections.filter { section in
            switch section {
            case .subagents: !liveSubagents.isEmpty
            case .branch: branch?.isWorktree == true
            case .linearIssues: linear?.issues.isEmpty == false
            case .folder, .sideChat: false
            case .backgroundTasks, .plan, .pullRequest, .artifacts: true
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
        (subagents.filter { !hasSettled($0) }, newestFirst(subagents.filter(hasSettled)))
    }

    /// Orders by last activity, newest first. Subagents with no timestamp
    /// follow the dated ones and keep their input order.
    static func newestFirst(_ subagents: [SubagentTranscript]) -> [SubagentTranscript] {
        let dated = subagents.enumerated().filter { $0.element.modifiedAt != nil }
        let undated = subagents.filter { $0.modifiedAt == nil }
        let sorted = dated.sorted {
            let (a, b) = ($0.element.modifiedAt!, $1.element.modifiedAt!)
            return a == b ? $0.offset < $1.offset : a > b
        }
        return sorted.map(\.element) + undated
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

extension InfoPaneFacts {
    static func linear(
        isEnabled: Bool,
        isConfigured: Bool,
        links: [LinkedLinearIssue],
        state: (String) -> LinearIssueFetchState?
    ) -> LinearFacts? {
        guard isEnabled, isConfigured else { return nil }
        return LinearFacts(issues: linearIssues(links: links, state: state))
    }

    /// Working issues first, then mentioned ones, each keeping its order.
    static func linearIssues(
        links: [LinkedLinearIssue],
        state: (String) -> LinearIssueFetchState?
    ) -> [LinearIssueFacts] {
        let facts = links.map { link -> LinearIssueFacts in
            let fetch = state(link.identifier)
            let issue = fetch?.issue
            return LinearIssueFacts(
                identifier: link.identifier,
                role: link.role,
                title: issue?.title,
                stateName: issue?.stateName,
                stateType: issue?.stateType,
                stateColor: issue?.stateColor,
                assignee: issue?.assigneeName,
                url: issue.flatMap { URL(string: $0.url) },
                attribution: attribution(of: link),
                sourceHint: link.role == .working ? sourceHint(of: link) : nil,
                statusWord: statusWord(for: fetch)
            )
        }
        return facts.filter { $0.role == .working } + facts.filter { $0.role == .mentioned }
    }

    static func attribution(of link: LinkedLinearIssue) -> String? {
        guard !link.subagents.isEmpty else { return nil }
        let subagents = link.subagents.map(\.label).joined(separator: ", ")
        return link.touchedByMainAgent ? "via \(subagents) and main agent" : "via \(subagents)"
    }

    static func sourceHint(of link: LinkedLinearIssue) -> String? {
        let words = link.sources.sorted().compactMap { source -> String? in
            switch source {
            case .branch: "branch"
            case .manual: "linked"
            case .agentStarted: "agent started"
            case .promoted: "marked working"
            case .agent: nil
            }
        }
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    static func statusWord(for state: LinearIssueFetchState?) -> String? {
        switch state {
        case .issue, .stale: nil
        case nil, .loading: "loading"
        case .notFound: "not found"
        case .noWorkspace: "no workspace"
        case .failed: "offline"
        case .unauthorized: "key rejected"
        case .rateLimited: "rate limited"
        }
    }
}

enum InfoPaneSection: Equatable {
    case linearIssues
    case subagents
    case backgroundTasks
    case plan
    case artifacts
    case sideChat
    case folder
    case branch
    case pullRequest
}

enum InfoPaneLayout {
    static let paneWidth: CGFloat = 280
    static let symbol = "checklist.unchecked"
    /// The shared width every row's icon centers in, so the text beside the
    /// icons starts on one edge.
    static let iconColumnWidth: CGFloat = 16
    static let columnSpacing: CGFloat = 6
    /// Above and below every row, so a clickable row's hover wash has room
    /// and plain rows keep the same rhythm.
    static let rowVerticalPadding: CGFloat = 5
    static let sectionAnimation: Animation = .snappy(duration: 0.22)

    /// The room a pinned pane takes from the chat's trailing edge: the pane,
    /// and the gap and minimap rail beyond it. The chat's own edge padding
    /// is the gap on the pane's other side.
    static func reservedWidth(railFootprint: CGFloat, gap: CGFloat) -> CGFloat {
        paneWidth + gap + railFootprint
    }

    /// Pinned beside the chat only while the chat keeps its full prose
    /// column, edge padding included, so no paragraph rewraps. Narrower than
    /// that the pane opens over the chat on demand instead.
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
        // Before the first measurement, so a pane left pinned opens pinned
        // rather than animating out of the collapsed form.
        let fits = width <= 0
            || fitsBeside(width: width, reservedWidth: reserved, chatColumnWidth: chatColumnWidth)
        let isPinned = fits && state == .expanded
        return SideGeometry(
            fitsBeside: fits,
            isPinned: isPinned,
            trailingInset: railFootprint + gap,
            chatTrailingReserve: isPinned ? reserved : 0,
            chatTopInset: collapsedHeight + gap
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
