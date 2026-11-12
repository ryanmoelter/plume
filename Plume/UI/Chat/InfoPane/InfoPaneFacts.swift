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
        /// The repository's checks ignored while pending, which the check
        /// list marks.
        var ignoredChecks: Set<String> = []

        var summary: PullRequestSummary? {
            guard case .pullRequest(let pullRequest) = state else { return nil }
            return PullRequestSummary(pullRequest, ignoredChecks: ignoredChecks)
        }

        var hasPullRequest: Bool {
            if case .pullRequest = state { true } else { false }
        }

        var url: URL? {
            guard case .pullRequest(let pullRequest) = state else { return nil }
            return pullRequest.url.flatMap(URL.init(string:))
        }
    }

    /// A pull request pinned to the task or named in the conversation, other
    /// than the branch's own.
    struct LinkedPullRequestFacts: Equatable, Identifiable {
        let reference: PullRequestReference
        var role: LinkedPullRequestRole = .mentioned
        /// Nil until GitHub has answered, and when it cannot.
        var pullRequest: MentionCandidate.PullRequestEntry?

        var id: String { reference.id }
    }

    /// One linked Linear issue, flattened for drawing.
    struct LinearIssueFacts: Equatable, Identifiable {
        let identifier: String
        let role: LinearLinkRole
        var title: String?
        var stateName: String?
        var stateType: LinearStateType?
        var stateColor: String?
        var statePosition: Double?
        var teamKey: String?
        var startedProgress: LinearStartedProgress = .half
        var assignee: String?
        var url: URL?
        /// Who touched the issue, when a subagent did.
        var attribution: String?
        /// Set when the state has no issue to show; nil when one is drawn.
        var statusWord: String?

        var id: String { identifier }
    }

    /// Nil when Linear is off or no workspace is connected. An empty list
    /// still shows the section, for its link button.
    struct LinearFacts: Equatable {
        /// Working issues, then mentioned ones still inside their linger.
        var main: [LinearIssueFacts]
        var mentioned: [LinearIssueFacts]

        var workingCount: Int { main.count { $0.role == .working } }
        var isEmpty: Bool { main.isEmpty && mentioned.isEmpty }
    }

    var tabID: UUID
    var liveSubagents: [SubagentTranscript] = []
    var completedSubagents: [SubagentTranscript] = []
    var backgroundTasks: [BackgroundTaskTracker.Entry] = []
    /// What the plan row reads, or nil when the conversation has no plan.
    var planTitle: String?
    /// The working directory's display name.
    var folder: String?
    /// Every folder the conversation reaches, the working directory first.
    var folderRows: [FolderRow] = []
    /// Claude Code takes `--add-dir`; Codex has no counterpart here.
    var canEditFolders = false
    /// Set while a folder change waits for the session to go idle.
    var folderRestart: FolderRestartFacts?
    var branch: Branch?
    /// Nil when PR status is turned off or the forge cannot answer.
    var pullRequest: PullRequestFacts?
    var linkedPullRequests: [LinkedPullRequestFacts] = []
    /// Shows the pull request section with nothing in it, for its pin button.
    var canPinPullRequests = false
    var linear: LinearFacts?
    /// How many `/btw` questions this tab has asked.
    var sideChatCount = 0
    var artifacts: [ConversationArtifact] = []
    /// Nil before a session exists, since there is no bridge to attach to.
    var remoteControl: RemoteControlStatus?

    var sections: [InfoPaneSection] {
        var sections: [InfoPaneSection] = []
        if !liveSubagents.isEmpty || !completedSubagents.isEmpty { sections.append(.subagents) }
        if !backgroundTasks.isEmpty { sections.append(.backgroundTasks) }
        if pullRequest?.hasPullRequest == true || !linkedPullRequests.isEmpty || canPinPullRequests {
            sections.append(.pullRequests)
        }
        if linear != nil { sections.append(.linearIssues) }
        if planTitle != nil { sections.append(.plan) }
        if !artifacts.isEmpty { sections.append(.artifacts) }
        if sideChatCount > 0 { sections.append(.sideChat) }
        if remoteControl != nil { sections.append(.remoteControl) }
        if folder != nil || !folderRows.isEmpty { sections.append(.folder) }
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
            case .linearIssues: (linear?.workingCount ?? 0) > 0
            case .remoteControl: remoteControl == .on
            case .pullRequests: pullRequest?.hasPullRequest == true
            case .folder, .sideChat: false
            case .backgroundTasks, .plan, .artifacts: true
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
        ignoredChecks: Set<String> = [],
        checkRollup: (PullRequest) -> CheckRollup
    ) -> PullRequestFacts? {
        guard let state else { return nil }
        switch state {
        case .forgeUnsupported:
            return nil
        case .pullRequest(let pullRequest):
            return PullRequestFacts(
                state: state,
                checkRollup: checkRollup(pullRequest),
                forge: forge,
                ignoredChecks: ignoredChecks
            )
        default:
            return PullRequestFacts(state: state, checkRollup: nil, forge: forge)
        }
    }
}

extension InfoPaneFacts {
    /// Pinned first, then mentioned. Leaves out the branch's own pull
    /// request, which leads the section on its own.
    static func linkedPullRequests(
        pinned: [PullRequestReference],
        mentioned: [PullRequestReference],
        branchPullRequestURL: URL?,
        detail: (PullRequestReference) -> LinkedPullRequestStore.Detail?
    ) -> [LinkedPullRequestFacts] {
        LinkedPullRequest.merge(pinned: pinned, mentioned: mentioned)
            .filter { !$0.reference.matches(url: branchPullRequestURL?.absoluteString) }
            .map { linked in
                var facts = LinkedPullRequestFacts(reference: linked.reference, role: linked.role)
                if case .pullRequest(let pull) = detail(linked.reference) { facts.pullRequest = pull }
                return facts
            }
    }
}

extension InfoPaneFacts {
    /// A mentioned issue counts as working-section material until
    /// `hasSettled` says its linger is over.
    static func linear(
        isEnabled: Bool,
        isConfigured: Bool,
        links: [LinkedLinearIssue],
        state: (String) -> LinearIssueFetchState?,
        startedProgress: (_ identifier: String, _ teamKey: String, _ position: Double?) -> LinearStartedProgress,
        hasSettled: (String) -> Bool
    ) -> LinearFacts? {
        guard isEnabled, isConfigured else { return nil }
        let issues = linearIssues(links: links, state: state, startedProgress: startedProgress)
        let settled = issues.filter { $0.role == .mentioned && hasSettled($0.identifier) }
        let settledIDs = Set(settled.map(\.identifier))
        return LinearFacts(main: issues.filter { !settledIDs.contains($0.identifier) }, mentioned: settled)
    }

    /// Working issues first, then mentioned ones, each sorted by `LinearIssueOrder`.
    static func linearIssues(
        links: [LinkedLinearIssue],
        state: (String) -> LinearIssueFetchState?,
        startedProgress: (_ identifier: String, _ teamKey: String, _ position: Double?) -> LinearStartedProgress = { _, _, _ in .half }
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
                statePosition: issue?.statePosition,
                teamKey: issue?.teamKey,
                startedProgress: issue.map { startedProgress(link.identifier, $0.teamKey, $0.statePosition) } ?? .half,
                assignee: issue?.assigneeName,
                url: issue.flatMap { URL(string: $0.url) },
                attribution: attribution(of: link),
                statusWord: statusWord(for: fetch)
            )
        }
        return LinearIssueOrder.sorted(facts.filter { $0.role == .working })
            + LinearIssueOrder.sorted(facts.filter { $0.role == .mentioned })
    }

    static func attribution(of link: LinkedLinearIssue) -> String? {
        guard !link.subagents.isEmpty else { return nil }
        let subagents = link.subagents.map(\.label).joined(separator: ", ")
        return link.touchedByMainAgent ? "via \(subagents) and main agent" : "via \(subagents)"
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

/// Started issues first, then unstarted, backlog, triage, other types,
/// completed, and canceled or duplicate. Within a type, issues group by team
/// in order of first appearance, and a later workflow state comes first
/// within a team: positions only compare inside one team. Issues with no
/// state yet go last.
enum LinearIssueOrder {
    static func typeRank(_ type: LinearStateType?) -> Int {
        switch type {
        case .started: 0
        case .unstarted: 1
        case .backlog: 2
        case .triage: 3
        case .other: 4
        case .completed: 5
        case .canceled, .duplicate: 6
        case nil: 7
        }
    }

    static func sorted(_ issues: [InfoPaneFacts.LinearIssueFacts]) -> [InfoPaneFacts.LinearIssueFacts] {
        var teamOrder: [String: Int] = [:]
        let keyed = issues.enumerated().map { offset, issue -> (offset: Int, issue: InfoPaneFacts.LinearIssueFacts, team: Int) in
            let team = issue.teamKey ?? ""
            let index = teamOrder[team] ?? teamOrder.count
            teamOrder[team] = index
            return (offset, issue, index)
        }
        return keyed.sorted { left, right in
            let (leftRank, rightRank) = (typeRank(left.issue.stateType), typeRank(right.issue.stateType))
            if leftRank != rightRank { return leftRank < rightRank }
            if left.team != right.team { return left.team < right.team }
            let (leftPosition, rightPosition) = (left.issue.statePosition ?? -.infinity, right.issue.statePosition ?? -.infinity)
            if leftPosition != rightPosition { return leftPosition > rightPosition }
            return left.offset < right.offset
        }.map(\.issue)
    }
}

enum InfoPaneSection: Equatable {
    case linearIssues
    case subagents
    case backgroundTasks
    case plan
    case artifacts
    case sideChat
    case remoteControl
    case folder
    case branch
    /// The branch's own pull request, then pinned and mentioned ones.
    case pullRequests
}

enum InfoPaneLayout {
    static let defaultPaneWidth: CGFloat = 280
    static let minimumPaneWidth: CGFloat = 240
    static let maximumPaneWidth: CGFloat = 480
    static let symbol = "checklist.unchecked"
    /// The shared width every row's icon centers in, so the text beside the
    /// icons starts on one edge.
    static let iconColumnWidth: CGFloat = 16
    static let columnSpacing: CGFloat = 6
    /// Above and below every row, so a clickable row's hover wash has room
    /// and plain rows keep the same rhythm.
    static let rowVerticalPadding: CGFloat = 5
    static let sectionAnimation: Animation = .snappy(duration: 0.22)
    /// Left of the pane's content edge, where a section header's stub and
    /// its bar sit.
    static let sectionGutter: CGFloat = 12
    static let bracketLineWidth: CGFloat = 1.5
    static let bracketCornerRadius: CGFloat = 4
    /// Between a header's stub and its title.
    static let bracketStubGap: CGFloat = 3
    static let subgroupGlyphSize = CGSize(width: 8, height: 12)
    static let subgroupGlyphCornerRadius: CGFloat = 3
    #if DEBUG
    /// Swaps the stub for a straight bar and the old chevron, for comparison.
    static let usesPlainBar = UserDefaults.standard.bool(forKey: "PlumeInfoPanePlainBar")
    #else
    static let usesPlainBar = false
    #endif

    static func clampedPaneWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumPaneWidth), maximumPaneWidth)
    }

    /// The room a pinned pane takes from the chat's trailing edge: the pane,
    /// and the gap and minimap rail beyond it. The chat's own edge padding
    /// is the gap on the pane's other side.
    static func reservedWidth(paneWidth: CGFloat, railFootprint: CGFloat, gap: CGFloat) -> CGFloat {
        paneWidth + gap + railFootprint
    }

    /// Whether a pinned pane sits beside the chat. It opens once the chat
    /// beside it keeps its full prose column, and closes only once the chat
    /// would drop below its comfortable minimum. Between the two it stays as
    /// it is, so a window resized across one threshold doesn't flicker.
    static func showsBeside(
        availableWidth: CGFloat,
        chatColumnWidth: CGFloat,
        comfortableChatWidth: CGFloat,
        reservedWidth: CGFloat,
        isShown: Bool,
        isPinned: Bool
    ) -> Bool {
        guard isPinned else { return false }
        let chatWidth = availableWidth - reservedWidth
        if chatWidth >= chatColumnWidth { return true }
        if chatWidth < comfortableChatWidth { return false }
        return isShown
    }

    /// Where the side pane sits over a chat `width` wide, and what room the
    /// chat gives it. `comfortableChatWidth` is the narrowest the chat gets
    /// beside a pinned pane, and never less than the chat's hard minimum.
    static func side(
        width: CGFloat,
        railFootprint: CGFloat,
        gap: CGFloat,
        chatColumnWidth: CGFloat,
        comfortableChatWidth: CGFloat,
        paneWidth: CGFloat,
        state: InfoPaneState,
        wasShownBeside: Bool,
        collapsedHeight: CGFloat
    ) -> SideGeometry {
        let paneWidth = clampedPaneWidth(paneWidth)
        let reserved = reservedWidth(paneWidth: paneWidth, railFootprint: railFootprint, gap: gap)
        // Before the first measurement, so a pane left pinned opens pinned
        // rather than animating out of the collapsed form.
        let isMeasured = width > 0
        let fits = !isMeasured || width - reserved >= comfortableChatWidth
        let isPinned = state == .expanded && (!isMeasured || showsBeside(
            availableWidth: width,
            chatColumnWidth: chatColumnWidth,
            comfortableChatWidth: comfortableChatWidth,
            reservedWidth: reserved,
            isShown: wasShownBeside,
            isPinned: true
        ))
        let maxPaneWidth = isMeasured
            ? min(maximumPaneWidth, max(minimumPaneWidth, width - gap - railFootprint - comfortableChatWidth))
            : maximumPaneWidth
        return SideGeometry(
            fitsBeside: fits,
            isPinned: isPinned,
            paneWidth: paneWidth,
            maxPaneWidth: maxPaneWidth,
            trailingInset: railFootprint + gap,
            chatTrailingReserve: isPinned ? reserved : 0,
            chatTopInset: collapsedHeight + gap
        )
    }

    /// How far down the minimap ignores the pointer: the collapsed pane's
    /// row, or the pinned pane up to a third of the chat, so a tall pane
    /// never walls off the whole minimap.
    static func minimapExclusionHeight(
        geometry: SideGeometry, openHeight: CGFloat, gap: CGFloat, chatHeight: CGFloat
    ) -> CGFloat {
        geometry.isPinned ? min(gap + openHeight, chatHeight / 3) : geometry.chatTopInset
    }

    struct SideGeometry: Equatable {
        /// The chat keeps its comfortable minimum beside the pane, so pinning
        /// would place the pane beside it rather than over it.
        var fitsBeside: Bool
        /// Open beside the chat rather than over it.
        var isPinned: Bool
        var paneWidth: CGFloat
        /// The widest a drag may make the pane without pushing the chat
        /// below its comfortable minimum.
        var maxPaneWidth: CGFloat
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
