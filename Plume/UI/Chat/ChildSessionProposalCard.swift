import SwiftUI

/// What a chat's proposal cards act on: the stored proposals of the tab the
/// chat belongs to.
///
/// Nil in the environment where no proposal can start, as inside a
/// subagent's own transcript, and the call then renders as a plain tool row.
struct ChatProposalBoard {
    let tabID: UUID
    /// Reads the tab's persisted proposals, so a card calling this from
    /// `body` redraws when one is started or dismissed.
    let store: () -> ChildSessionProposalStore
    let start: (String) -> Void
    let dismiss: (String) -> Void
}

extension EnvironmentValues {
    @Entry var chatProposalBoard: ChatProposalBoard?
}

/// A `start_session` call that proposed a session rather than starting one:
/// its title and brief, with Start and Dismiss while it is pending, then what
/// became of it. A started card selects the child's tab.
struct ChildSessionProposalCard: View, ThemedView {
    @Environment(\.theme) var theme

    let proposalID: String
    let board: ChatProposalBoard
    /// The call's own title and brief, for a proposal the store has pruned.
    let fallback: (title: String, prompt: String)

    static let briefLineLimit = 3

    var body: some View {
        let stored = board.store()
        let proposal = stored.proposal(id: proposalID)
        let activity = ChildSessionProposalActivity.shared
        let isStarting = activity.isStarting(proposalID, in: board.tabID)
        let state = stored.cardState(id: proposalID, now: .now)
        VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
            DecisionCardHeader(
                title: "Proposed session",
                symbol: "arrow.turn.down.right",
                subject: state == .pending ? .inquiry : nil
            )
            Text(proposal?.title ?? fallback.title)
                .font(typography.body.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .chatTextColumn()
            Text(proposal?.prompt ?? fallback.prompt)
                .font(typography.caption.font)
                .emphasis(.secondary)
                .lineLimit(Self.briefLineLimit)
                .truncationMode(.tail)
                .chatTextColumn()
            footer(state: state, isStarting: isStarting)
            if state == .pending, let failure = activity.failure(of: proposalID, in: board.tabID) {
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
