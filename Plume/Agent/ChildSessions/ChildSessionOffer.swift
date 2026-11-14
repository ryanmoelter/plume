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
    /// call's result says what became of it. Nil for a call that failed for
    /// another reason, such as a missing brief, which renders as a plain tool
    /// row.
    static func reading(
        live: ChildSessionOfferCardState?, result: String?, didFail: Bool, isTurnRunning: Bool
    ) -> ChildSessionOfferCardState? {
        if let live { return live }
        guard let result else { return isTurnRunning ? .waiting : .unanswered }
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

    func offer(_ toolUseID: String) -> Offer? { offers[toolUseID] }

    func raise(_ toolUseID: String, parentTabID: UUID, request: StartSessionRequest) {
        offers[toolUseID] = Offer(parentTabID: parentTabID, request: request, state: .pending)
        queued[toolUseID] = []
    }

    /// The card's buttons. Ignored unless the card is pending, so a double
    /// click starts one session.
    func answer(_ toolUseID: String, _ action: ChildSessionOfferAction) {
        guard offers[toolUseID]?.state == .pending || action == .withdraw else { return }
        post(action, to: toolUseID)
    }

    func withdrawAll(inTab tabID: UUID) {
        for (id, offer) in offers where offer.parentTabID == tabID && offer.state.isLive {
            post(.withdraw, to: id)
        }
    }

    /// Waits for the user's next action on the offer.
    func nextAction(_ toolUseID: String) async -> ChildSessionOfferAction {
        if var actions = queued[toolUseID], !actions.isEmpty {
            let next = actions.removeFirst()
            queued[toolUseID] = actions
            return next
        }
        return await withCheckedContinuation { waiters[toolUseID] = $0 }
    }

    func setStarting(_ toolUseID: String) {
        offers[toolUseID]?.state = .starting
        offers[toolUseID]?.failure = nil
    }

    func fail(_ toolUseID: String, _ failure: String) {
        offers[toolUseID]?.state = .pending
        offers[toolUseID]?.failure = failure
    }

    func settle(_ toolUseID: String, _ state: ChildSessionOfferCardState, result: String) {
        offers[toolUseID]?.state = state
        offers[toolUseID]?.failure = nil
        offers[toolUseID]?.result = result
        queued.removeValue(forKey: toolUseID)
        waiters.removeValue(forKey: toolUseID)?.resume(returning: .withdraw)
    }

    /// A closing tab's live offers are withdrawn, and its settled ones are
    /// dropped: their results say what became of them.
    func forget(_ tabID: UUID) {
        withdrawAll(inTab: tabID)
        offers = offers.filter { $0.value.parentTabID != tabID || $0.value.state.isLive }
    }

    private func post(_ action: ChildSessionOfferAction, to toolUseID: String) {
        guard offers[toolUseID]?.state.isLive == true else { return }
        if let waiter = waiters.removeValue(forKey: toolUseID) {
            waiter.resume(returning: action)
        } else {
            queued[toolUseID, default: []].append(action)
        }
    }
}
