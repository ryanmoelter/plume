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

/// `child-session.propose`: the `start_session` arguments of an
/// `own_initiative` call, from `parent`.
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

    private enum CodingKeys: String, CodingKey {
        case parent, title, prompt, background, name, context, model, effort
        case useWorktree = "use_worktree"
        case permissionMode = "permission_mode"
    }
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
        var arguments: [String: JSONValue] = ["initiation": .string(StartSessionRequest.Initiation.ownInitiative.rawValue)]
        for (key, value) in [
            ("title", params.title), ("prompt", params.prompt), ("background", params.background),
            ("name", params.name), ("context", params.context), ("model", params.model),
            ("effort", params.effort), ("permission_mode", params.permissionMode)
        ] {
            if let value { arguments[key] = .string(value) }
        }
        if let useWorktree = params.useWorktree { arguments["use_worktree"] = .bool(useWorktree) }
        let request: StartSessionRequest
        switch StartSessionRequest.parse(arguments) {
        case .success(let parsed): request = parsed
        case .failure(let error): throw ControlError.badParams(error.message)
        }
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
