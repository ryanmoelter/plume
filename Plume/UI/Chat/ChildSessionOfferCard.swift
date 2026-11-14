import SwiftUI

/// A `start_session` call that offered a session: its title and brief, with
/// "New session" and "Do it here" while the call waits on the user, then what
/// became of it. A started card selects the child's tab.
struct ChildSessionOfferCard: View, ThemedView {
    @Environment(\.theme) var theme

    let call: ToolCall
    let state: ChildSessionOfferCardState
    let text: (title: String, prompt: String)
    let failure: String?

    /// The card for `call`, or nil when the call failed for another reason
    /// and should render as a plain tool row. `ownerTabID` is the tab whose
    /// session made the call.
    @MainActor
    static func card(for call: ToolCall, ownerTabID: UUID) -> ChildSessionOfferCard? {
        guard let arguments = ChildSessionFormats.offerArguments(of: call) else { return nil }
        let live = ChildSessionOfferBoard.shared.offer(call.id)
        let session = AgentSessionManager.shared.existingSession(for: ownerTabID) as? HeadlessSession
        let isTurnRunning = session.map { !$0.hasExited && $0.isWorking } ?? false
        guard let state = ChildSessionOfferCardState.reading(
            live: live?.state, result: call.result, didFail: call.didFail, isTurnRunning: isTurnRunning
        ) else { return nil }
        let text = live.map { (title: $0.request.title, prompt: $0.request.prompt) } ?? arguments
        return ChildSessionOfferCard(call: call, state: state, text: text, failure: live?.failure)
    }

    static let briefLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
            DecisionCardHeader(
                title: "Offered session",
                symbol: "arrow.turn.down.right",
                subject: state.isLive ? .inquiry : nil
            )
            Text(text.title)
                .font(typography.body.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .chatTextColumn()
            Text(MarkdownCache.inline(text.prompt))
                .font(typography.caption.font)
                .emphasis(.secondary)
                .lineLimit(Self.briefLineLimit)
                .truncationMode(.tail)
                .chatTextColumn()
            footer
            if let failure, state == .pending {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(typography.caption.font)
                    .foregroundStyle(colors.warning)
                    .lineLimit(2)
                    .chatTextColumn()
            }
        }
        .decisionCard(subject: state.isLive ? .inquiry : nil, colors: colors)
        .listItemPadding(vertical: false)
    }

    @ViewBuilder
    private var footer: some View {
        switch state {
        case .pending, .starting:
            let isStarting = state == .starting
            HStack(spacing: DecisionCard.nestedPadding) {
                if isStarting {
                    Text("Starting…").emphasis(.secondary)
                }
                Spacer()
                Button("Do it here", action: doItHere)
                    .plumeID(AccessibilityID.offerDoItHereButton, label: call.id, invoke: doItHere)
                    .disabled(isStarting)
                Button("New session", action: newSession)
                    .buttonStyle(.borderedProminent)
                    .plumeID(AccessibilityID.offerNewSessionButton, label: call.id, invoke: newSession)
                    .disabled(isStarting)
            }
            .font(typography.caption.font)
            .plumeID(AccessibilityID.offerState, label: call.id, value: state.word)
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
                AccessibilityID.offerState,
                label: call.id,
                value: "\(state.word): \(name)",
                invoke: { ChildSessionCoordinator.shared.select(sessionID: sessionID) }
            )
            .chatTextColumn()
        case .declined:
            settled("Doing it here")
        case .withdrawn:
            settled("Withdrawn")
        case .unanswered:
            settled("Never answered")
        case .waiting:
            settled("Waiting…")
        }
    }

    private func settled(_ text: String) -> some View {
        Text(text)
            .font(typography.caption.font)
            .emphasis(.subtle)
            .plumeID(AccessibilityID.offerState, label: call.id, value: state.word)
            .chatTextColumn()
    }

    private func newSession() { ChildSessionOfferBoard.shared.answer(call.id, .newSession) }
    private func doItHere() { ChildSessionOfferBoard.shared.answer(call.id, .doItHere) }
}
