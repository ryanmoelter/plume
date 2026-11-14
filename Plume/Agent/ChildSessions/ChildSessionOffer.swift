import Foundation
import Observation

/// What the user can do with an offer's card, plus the withdrawal Plume makes
/// when the call stops waiting.
nonisolated enum ChildSessionOfferAction: String, Equatable, Sendable {
    case newSession = "new_session"
    case doItHere = "do_it_here"
    case withdraw
}

/// How an offer's card reads.
nonisolated enum ChildSessionOfferCardState: Equatable {
    /// The call is in the chat but Plume has not received it yet.
    case waiting
    case pending
    case starting
    case started(sessionID: String, name: String)
    /// The user chose "Do it here".
    case declined
    /// The turn ended, by an interrupt or an exit, before the user answered.
    case withdrawn
    /// No answer reached the call, and nothing is waiting for one now, as
    /// after a relaunch.
    case unanswered

    /// Where Plume holds the offer, it reads as Plume holds it. Otherwise the
    /// call's result says what became of it, and a call with no result reads
    /// as waiting only while the chat's own session is running a turn: a
    /// restored chat's call will never be answered. Nil for a call that
    /// failed for another reason, such as a missing brief, which renders as a
    /// plain tool row.
    static func reading(
        live: ChildSessionOfferCardState?, result: String?, didFail: Bool, turnIsRunning: Bool
    ) -> ChildSessionOfferCardState? {
        if let live { return live }
        guard let result else { return turnIsRunning ? .waiting : .unanswered }
        if !didFail, let started = ChildSessionFormats.startedSession(in: result) {
            return .started(sessionID: started.sessionID, name: started.name)
        }
        if !didFail, result.hasPrefix(ChildSessionFormats.offerDeclinedPrefix) {
            return .declined
        }
        if result == ChildSessionFormats.offerWithdrawn || ChildSessionFormats.isInterruptedToolResult(result) {
            return .withdrawn
        }
        return nil
    }

    var isLive: Bool { self == .pending || self == .starting }

    /// The control server's word for the state.
    var word: String {
        switch self {
        case .waiting: "waiting"
        case .pending: "pending"
        case .starting: "starting"
        case .started: "started"
        case .declined: "doing it here"
        case .withdrawn: "withdrawn"
        case .unanswered: "never answered"
        }
    }
}

/// The offers waiting on the user, and what became of each one raised since
/// launch, keyed by the `start_session` call's tool use id. In memory only: a
/// relaunch ends the process whose call was waiting.
///
/// A pending offer makes its tab need the user, the way a pending permission
/// does (`HeadlessSession.setOffer(_:waitsForUser:)`).
@MainActor
@Observable
final class ChildSessionOfferBoard {
    static let shared = ChildSessionOfferBoard()

    struct Offer: Equatable {
        let parentTabID: UUID
        let request: StartSessionRequest
        var state: ChildSessionOfferCardState
        /// Why the user's last "New session" failed, shown while the card is
        /// pending again.
        var failure: String?
        /// What the call returned, once it has.
        var result: String?
    }

    private(set) var offers: [String: Offer] = [:]
    @ObservationIgnored private var queued: [String: [ChildSessionOfferAction]] = [:]
    @ObservationIgnored private var waiters: [String: CheckedContinuation<ChildSessionOfferAction, Never>] = [:]
    /// The task waiting on an offer the control server raised. No CLI call
    /// owns it, so nothing else would cancel it.
    @ObservationIgnored private var hostTasks: [String: Task<Void, Never>] = [:]

    func offer(_ toolUseID: String) -> Offer? { offers[toolUseID] }

    func raise(_ toolUseID: String, parentTabID: UUID, request: StartSessionRequest) {
        offers[toolUseID] = Offer(parentTabID: parentTabID, request: request, state: .pending)
        queued[toolUseID] = []
        reportAttention(toolUseID)
    }

    /// The card's buttons. Ignored unless the card is pending, and the card
    /// leaves pending at once, so a second click before the call takes the
    /// first does nothing.
    func answer(_ toolUseID: String, _ action: ChildSessionOfferAction) {
        switch action {
        case .withdraw:
            hostTasks.removeValue(forKey: toolUseID)?.cancel()
            post(.withdraw, to: toolUseID)
        case .newSession, .doItHere:
            guard offers[toolUseID]?.state == .pending else { return }
            post(action, to: toolUseID)
            offers[toolUseID]?.state = action == .newSession ? .starting : .declined
            reportAttention(toolUseID)
        }
    }

    func withdrawAll(inTab tabID: UUID) {
        for (id, offer) in offers where offer.parentTabID == tabID && offer.result == nil {
            answer(id, .withdraw)
        }
    }

    /// Whether the call should stop waiting: the offer is gone, or a
    /// withdrawal arrived while the call was busy launching.
    func isWithdrawn(_ toolUseID: String) -> Bool {
        offers[toolUseID] == nil || queued[toolUseID]?.contains(.withdraw) == true
    }

    /// Waits for the user's next action on the offer. A withdrawal goes
    /// ahead of any click, and an offer that is gone reads as withdrawn.
    func nextAction(_ toolUseID: String) async -> ChildSessionOfferAction {
        guard offers[toolUseID] != nil else { return .withdraw }
        if var actions = queued[toolUseID], !actions.isEmpty {
            let next = actions.contains(.withdraw) ? .withdraw : actions.removeFirst()
            queued[toolUseID] = actions
            return next
        }
        return await withCheckedContinuation { waiters[toolUseID] = $0 }
    }

    func own(_ task: Task<Void, Never>, for toolUseID: String) {
        hostTasks[toolUseID] = task
    }

    func setStarting(_ toolUseID: String) {
        offers[toolUseID]?.state = .starting
        offers[toolUseID]?.failure = nil
    }

    /// Puts the card back to pending for a new click. Nothing clicked while
    /// it was starting carries over.
    func fail(_ toolUseID: String, _ failure: String) {
        offers[toolUseID]?.state = .pending
        offers[toolUseID]?.failure = failure
        queued[toolUseID] = []
        reportAttention(toolUseID)
    }

    func settle(_ toolUseID: String, _ state: ChildSessionOfferCardState, result: String) {
        offers[toolUseID]?.state = state
        offers[toolUseID]?.failure = nil
        offers[toolUseID]?.result = result
        queued.removeValue(forKey: toolUseID)
        hostTasks.removeValue(forKey: toolUseID)
        waiters.removeValue(forKey: toolUseID)?.resume(returning: .withdraw)
        reportAttention(toolUseID)
    }

    /// A closing tab's offers are dropped, live or settled: a live one's call
    /// stops waiting, and a settled one's result says what became of it.
    func forget(_ tabID: UUID) {
        for id in offers.filter({ $0.value.parentTabID == tabID }).map(\.key) {
            offers.removeValue(forKey: id)
            queued.removeValue(forKey: id)
            hostTasks.removeValue(forKey: id)?.cancel()
            waiters.removeValue(forKey: id)?.resume(returning: .withdraw)
        }
    }

    private func post(_ action: ChildSessionOfferAction, to toolUseID: String) {
        guard let offer = offers[toolUseID], offer.result == nil else { return }
        if let waiter = waiters.removeValue(forKey: toolUseID) {
            waiter.resume(returning: action)
        } else {
            queued[toolUseID, default: []].append(action)
        }
    }

    private func reportAttention(_ toolUseID: String) {
        guard let offer = offers[toolUseID],
              let session = AgentSessionManager.shared.existingSession(for: offer.parentTabID) as? HeadlessSession
        else { return }
        session.setOffer(toolUseID, waitsForUser: offer.state == .pending)
    }
}
