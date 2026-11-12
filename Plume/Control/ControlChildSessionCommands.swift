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
/// true, as for a turn the parent started.
nonisolated struct ChildSessionReportParams: Decodable, Equatable {
    var child: String?
    var text: String?
    var wakes: Bool?
}

nonisolated struct ChildSessionResult: Encodable, Equatable {
    let parentTabID: UUID
    let childTabID: UUID?
    let message: String
}

/// `child-session.start` and `child-session.report`: start a child session as
/// if the parent's agent had called `start_session`, and report a turn as if
/// a child had finished one, without a model in the loop.
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
        ChildSessionCoordinator.shared.simulateTurnFinished(in: child, text: text, hostDriven: params.wakes ?? true)
        return ChildSessionResult(parentTabID: parent.id, childTabID: child.id, message: "reported")
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
