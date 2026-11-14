#if DEBUG
import Foundation
import SwiftData

/// `parent` is a tab's UUID, or a substring of its title.
nonisolated struct ChildSessionStartParams: Decodable, Equatable {
    var parent: String?
    var title: String?
    var prompt: String?
    var background: String?
    var name: String?
    var useWorktree: Bool?
    var context: String?

    private enum CodingKeys: String, CodingKey {
        case parent, title, prompt, background, name, context
        case useWorktree = "use_worktree"
    }
}

/// `child` is a tab's UUID, or a substring of its title. `wakes` defaults to
/// true; false reports an interrupted turn, which never wakes.
nonisolated struct ChildSessionReportParams: Decodable, Equatable {
    var child: String?
    var text: String?
    var wakes: Bool?
}

/// `child-session.propose` and `child-session.offer`: the `start_session`
/// arguments of an `own_initiative` or `offer` call, from `parent`. An offer's
/// `tool_use_id` names the call whose chat row shows the card; without one
/// the offer gets a minted id and no card.
nonisolated struct ChildSessionProposeParams: Decodable, Equatable {
    var parent: String?
    var title: String?
    var prompt: String?
    var background: String?
    var name: String?
    var useWorktree: Bool?
    var context: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var toolUseID: String?

    private enum CodingKeys: String, CodingKey {
        case parent, title, prompt, background, name, context, model, effort
        case useWorktree = "use_worktree"
        case permissionMode = "permission_mode"
        case toolUseID = "tool_use_id"
    }
}

/// `child-session.offer.answer`: `answer` is `new_session`, `do_it_here` or
/// `withdraw`.
nonisolated struct ChildSessionOfferAnswerParams: Decodable, Equatable {
    var toolUseID: String?
    var answer: String?

    private enum CodingKeys: String, CodingKey {
        case answer
        case toolUseID = "tool_use_id"
    }
}

nonisolated struct ChildSessionOffersResult: Encodable, Equatable {
    struct Entry: Encodable, Equatable {
        let toolUseID: String
        let title: String
        /// `ChildSessionOfferCardState.word`.
        let state: String
        let failure: String?
        let result: String?
    }

    let parentTabID: UUID
    let offers: [Entry]
}

/// `child-session.proposal.start` and `.dismiss`. `by` is `user` (default),
/// as from the card, or `agent`, as from the parent's own tool call.
nonisolated struct ChildSessionProposalParams: Decodable, Equatable {
    enum Actor: String, Decodable {
        case user
        case agent
    }

    var parent: String?
    var taskID: String?
    var reason: String?
    var by: Actor?

    private enum CodingKeys: String, CodingKey {
        case parent, reason, by
        case taskID = "task_id"
    }
}

nonisolated struct ChildSessionProposalsParams: Decodable, Equatable {
    var parent: String?
}

nonisolated struct ChildSessionResult: Encodable, Equatable {
    let parentTabID: UUID
    let childTabID: UUID?
    let message: String
    var taskID: String?
}

nonisolated struct ChildSessionProposalsResult: Encodable, Equatable {
    struct Entry: Encodable, Equatable {
        let taskID: String
        let title: String
        let name: String?
        /// `pending`, `started`, `dismissed` or `expired`.
        let state: String
        let startedSessionID: String?
        let createdAt: Date
    }

    let parentTabID: UUID
    let proposals: [Entry]
}

/// `child-session.*`: start a child session as if the parent's agent had
/// called `start_session`, report a turn as if a child had finished one, and
/// propose, list, start and dismiss proposals, without a model in the loop.
@MainActor
enum ControlChildSessionCommands {
    static func start(_ params: ChildSessionStartParams, in context: ModelContext) async throws -> ChildSessionResult {
        let parent = try tab(params.parent, in: context)
        var arguments: [String: JSONValue] = ["initiation": .string(StartSessionRequest.Initiation.userAsked.rawValue)]
        for (key, value) in [
            ("title", params.title), ("prompt", params.prompt), ("background", params.background),
            ("name", params.name), ("context", params.context)
        ] {
            if let value { arguments[key] = .string(value) }
        }
        if let useWorktree = params.useWorktree { arguments["use_worktree"] = .bool(useWorktree) }
        let request: StartSessionRequest
        switch StartSessionRequest.parse(arguments) {
        case .success(let parsed): request = parsed
        case .failure(let error): throw ControlError.badParams(error.message)
        }
        let before = Set(parent.task?.liveTabs.map(\.id) ?? [])
        switch await ChildSessionCoordinator.shared.startSession(request, from: parent) {
        case .success(let message):
            let child = parent.task?.liveTabs.first { !before.contains($0.id) && $0.parentTabID == parent.id }
            return ChildSessionResult(parentTabID: parent.id, childTabID: child?.id, message: message)
        case .failure(let error):
            throw ControlError.badParams(error.message)
        }
    }

    static func report(_ params: ChildSessionReportParams, in context: ModelContext) throws -> ChildSessionResult {
        let child = try tab(params.child, in: context)
        guard let parent = ChildSessionCoordinator.shared.parent(of: child) else {
            throw ControlError.notFound("an open parent of tab \(child.id)")
        }
        guard let text = params.text else { throw ControlError.badParams("child-session.report needs text") }
        ChildSessionCoordinator.shared.simulateTurnFinished(in: child, text: text, wakes: params.wakes ?? true)
        return ChildSessionResult(parentTabID: parent.id, childTabID: child.id, message: "reported")
    }

    static func propose(_ params: ChildSessionProposeParams, in context: ModelContext) throws -> ChildSessionResult {
        let parent = try tab(params.parent, in: context)
        let request = try request(params, initiation: .ownInitiative)
        switch ChildSessionCoordinator.shared.propose(request, from: parent) {
        case .success(let proposal):
            let message = ChildSessionFormats.proposed(title: proposal.title, taskID: proposal.id)
            return ChildSessionResult(parentTabID: parent.id, childTabID: nil, message: message, taskID: proposal.id)
        case .failure(let error):
            throw ControlError.badParams(error.message)
        }
    }

    static func proposals(_ params: ChildSessionProposalsParams, in context: ModelContext) throws -> ChildSessionProposalsResult {
        let parent = try tab(params.parent, in: context)
        let now = Date.now
        let store = ChildSessionCoordinator.shared.proposals(of: parent, now: now)
        return ChildSessionProposalsResult(parentTabID: parent.id, proposals: store.proposals.map { proposal in
            let state = switch store.cardState(id: proposal.id, now: now) {
            case .pending: "pending"
            case .started: "started"
            case .dismissed: "dismissed"
            case .expired: "expired"
            case .elsewhere: "elsewhere"
            }
            return .init(
                taskID: proposal.id, title: proposal.title, name: proposal.name, state: state,
                startedSessionID: proposal.startedSessionID, createdAt: proposal.createdAt
            )
        })
    }

    static func startProposal(_ params: ChildSessionProposalParams, in context: ModelContext) async throws -> ChildSessionResult {
        let parent = try tab(params.parent, in: context)
        guard let taskID = params.taskID else { throw ControlError.badParams("name the proposal by its task_id") }
        let byUser = (params.by ?? .user) == .user
        switch await ChildSessionCoordinator.shared.startProposal(taskID, from: parent, byUser: byUser) {
        case .success(let message):
            let sessionID = ChildSessionProposalStore(json: parent.childProposalsJSON).proposal(id: taskID)?.startedSessionID
            return ChildSessionResult(
                parentTabID: parent.id, childTabID: sessionID.flatMap(UUID.init(uuidString:)), message: message, taskID: taskID
            )
        case .failure(let error):
            throw ControlError.badParams(error.message)
        }
    }

    static func dismissProposal(_ params: ChildSessionProposalParams, in context: ModelContext) throws -> ChildSessionResult {
        let parent = try tab(params.parent, in: context)
        guard let taskID = params.taskID else { throw ControlError.badParams("name the proposal by its task_id") }
        let byUser = (params.by ?? .user) == .user
        switch ChildSessionCoordinator.shared.dismissProposal(taskID, reason: params.reason, from: parent, byUser: byUser) {
        case .success(let message):
            return ChildSessionResult(parentTabID: parent.id, childTabID: nil, message: message, taskID: taskID)
        case .failure(let error):
            throw ControlError.badParams(error.message)
        }
    }

    /// Raises the card and returns at once. The call's answer lands in
    /// `child-session.offers` once the offer is answered.
    static func offer(_ params: ChildSessionProposeParams, in context: ModelContext) throws -> ChildSessionResult {
        let parent = try tab(params.parent, in: context)
        let request = try request(params, initiation: .offer)
        let toolUseID = params.toolUseID ?? ChildSessionCoordinator.mintOfferID()
        let coordinator = ChildSessionCoordinator.shared
        if let refusal = coordinator.raiseOffer(request, from: parent, toolUseID: toolUseID) {
            throw ControlError.badParams(refusal.message)
        }
        Task { _ = await coordinator.awaitOffer(request, from: parent, toolUseID: toolUseID) }
        return ChildSessionResult(parentTabID: parent.id, childTabID: nil, message: "offered", taskID: toolUseID)
    }

    static func offers(_ params: ChildSessionProposalsParams, in context: ModelContext) throws -> ChildSessionOffersResult {
        let parent = try tab(params.parent, in: context)
        let entries = ChildSessionOfferBoard.shared.offers
            .filter { $0.value.parentTabID == parent.id }
            .sorted { $0.key < $1.key }
            .map { id, offer in
                ChildSessionOffersResult.Entry(
                    toolUseID: id, title: offer.request.title, state: offer.state.word,
                    failure: offer.failure, result: offer.result
                )
            }
        return ChildSessionOffersResult(parentTabID: parent.id, offers: entries)
    }

    static func answerOffer(_ params: ChildSessionOfferAnswerParams) throws -> ChildSessionResult {
        guard let toolUseID = params.toolUseID else { throw ControlError.badParams("name the offer by its tool_use_id") }
        guard let answer = params.answer.flatMap(ChildSessionOfferAction.init(rawValue:)) else {
            throw ControlError.badParams("answer is new_session, do_it_here or withdraw")
        }
        let board = ChildSessionOfferBoard.shared
        guard let offer = board.offer(toolUseID) else { throw ControlError.notFound("an offer \(toolUseID)") }
        guard offer.state == .pending || (answer == .withdraw && offer.state.isLive) else {
            throw ControlError.badParams("the offer is \(offer.state.word), not pending")
        }
        board.answer(toolUseID, answer)
        return ChildSessionResult(parentTabID: offer.parentTabID, childTabID: nil, message: "answered", taskID: toolUseID)
    }

    private static func request(
        _ params: ChildSessionProposeParams, initiation: StartSessionRequest.Initiation
    ) throws -> StartSessionRequest {
        var arguments: [String: JSONValue] = ["initiation": .string(initiation.rawValue)]
        for (key, value) in [
            ("title", params.title), ("prompt", params.prompt), ("background", params.background),
            ("name", params.name), ("context", params.context), ("model", params.model),
            ("effort", params.effort), ("permission_mode", params.permissionMode)
        ] {
            if let value { arguments[key] = .string(value) }
        }
        if let useWorktree = params.useWorktree { arguments["use_worktree"] = .bool(useWorktree) }
        switch StartSessionRequest.parse(arguments) {
        case .success(let parsed): return parsed
        case .failure(let error): throw ControlError.badParams(error.message)
        }
    }

    private static func tab(_ reference: String?, in context: ModelContext) throws -> TaskTab {
        guard let reference, !reference.isEmpty else { throw ControlError.badParams("name the tab by its ID or title") }
        let tasks = try ControlTabCommands.liveTasks(in: context)
        if let id = UUID(uuidString: reference) {
            return try ControlTabCommands.tab(id: id, label: nil, among: tasks)
        }
        return try ControlTabCommands.tab(id: nil, label: reference, among: tasks)
    }
}
#endif
