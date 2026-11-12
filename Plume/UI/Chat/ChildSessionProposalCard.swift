import SwiftUI

/// What a chat's proposal cards act on: the stored proposals of the tab that
/// made them. That is the chat's own tab, or for a child, its parent.
///
/// Nil in the environment where no proposal can start, as inside a
/// subagent's own transcript, and the call then renders as a plain tool row.
struct ChatProposalBoard {
    /// The tab that owns the proposals.
    let tabID: UUID
    /// Reads the owner's persisted proposals, so a card calling this from
    /// `body` redraws when one is started or dismissed. Empty when the owner
    /// has closed.
    let store: () -> ChildSessionProposalStore
    let start: (String) -> Void
    let dismiss: (String) -> Void
}

extension EnvironmentValues {
    @Entry var chatProposalBoard: ChatProposalBoard?
}

/// Each tab's decoded proposals, kept until its JSON changes, so a card's
/// `body` doesn't decode them on every render.
@MainActor
final class ChildSessionProposalStoreCache {
    static let shared = ChildSessionProposalStoreCache()

    private var entries: [UUID: (json: String, store: ChildSessionProposalStore)] = [:]

    func store(for tab: TaskTab) -> ChildSessionProposalStore {
        let json = tab.childProposalsJSON
        if let entry = entries[tab.id], entry.json == json { return entry.store }
        let store = ChildSessionProposalStore(json: json)
        entries[tab.id] = (json, store)
        return store
    }

    func forget(_ tabID: UUID) {
        entries.removeValue(forKey: tabID)
    }
}

/// A `start_session` call that proposed a session rather than starting one:
/// its title and brief, with Start and Dismiss while it is pending, then what
/// became of it. A started card selects the child's tab.
struct ChildSessionProposalCard: View, ThemedView {
    @Environment(\.theme) var theme

    let proposalID: String
    let board: ChatProposalBoard
    /// The call's own title and brief, for a proposal the store doesn't hold.
    let fallback: () -> (title: String, prompt: String)

    static let briefLineLimit = 3

    var body: some View {
        let stored = board.store()
        let expiry = stored.proposal(id: proposalID).flatMap { proposal in
            proposal.status == .pending && proposal.expiresAt > .now ? proposal.expiresAt : nil
        }
        TimelineView(.explicit(expiry.map { [$0] } ?? [])) { _ in
            card(stored)
        }
    }

    private func card(_ stored: ChildSessionProposalStore) -> some View {
        let proposal = stored.proposal(id: proposalID)
        let text = proposal.map { (title: $0.title, prompt: $0.prompt) } ?? fallback()
        let activity = ChildSessionProposalActivity.shared
        let isStarting = activity.isStarting(proposalID, in: board.tabID)
        let state = stored.cardState(id: proposalID, now: .now)
        return VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
            DecisionCardHeader(
                title: "Proposed session",
                symbol: "arrow.turn.down.right",
                subject: state == .pending ? .inquiry : nil
            )
            Text(text.title)
                .font(typography.body.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .chatTextColumn()
            Text(text.prompt)
                .font(typography.caption.font)
                .emphasis(.secondary)
                .lineLimit(Self.briefLineLimit)
                .truncationMode(.tail)
                .chatTextColumn()
            footer(state: state, isStarting: isStarting)
            if state == .pending || state == .expired, let failure = activity.failure(of: proposalID, in: board.tabID) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(typography.caption.font)
                    .foregroundStyle(colors.warning)
                    .lineLimit(2)
                    .chatTextColumn()
            }
        }
        .decisionCard(subject: state == .pending ? .inquiry : nil, colors: colors)
        .listItemPadding(vertical: false)
    }

    @ViewBuilder
    private func footer(state: ChildSessionProposalCardState, isStarting: Bool) -> some View {
        switch state {
        case .pending:
            HStack(spacing: DecisionCard.nestedPadding) {
                if isStarting {
                    Text("Starting…").emphasis(.secondary)
                }
                Spacer()
                Button("Dismiss", action: dismiss)
                    .plumeID(AccessibilityID.proposalDismissButton, label: proposalID, invoke: dismiss)
                    .disabled(isStarting)
                Button("Start", action: start)
                    .buttonStyle(.borderedProminent)
                    .plumeID(AccessibilityID.proposalStartButton, label: proposalID, invoke: start)
                    .disabled(isStarting)
            }
            .font(typography.caption.font)
            .chatTextColumn()
        case .started(let sessionID, let name):
            Button {
                ChildSessionCoordinator.shared.select(sessionID: sessionID)
            } label: {
                Label("Started as \(name)", systemImage: "arrow.turn.down.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show this session")
            .font(typography.caption.font)
            .emphasis(.secondary)
            .plumeID(
                AccessibilityID.proposalStartedRow,
                label: proposalID,
                value: name,
                invoke: { ChildSessionCoordinator.shared.select(sessionID: sessionID) }
            )
            .chatTextColumn()
        case .dismissed:
            settled("Dismissed")
        case .expired:
            settled("Expired")
        case .elsewhere:
            settled("Proposed in another session")
        }
    }

    private func settled(_ text: String) -> some View {
        Text(text)
            .font(typography.caption.font)
            .emphasis(.subtle)
            .plumeID(AccessibilityID.proposalState, label: proposalID, value: text.lowercased())
            .chatTextColumn()
    }

    private func start() { board.start(proposalID) }
    private func dismiss() { board.dismiss(proposalID) }
}
