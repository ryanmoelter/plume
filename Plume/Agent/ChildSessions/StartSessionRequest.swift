import Foundation

/// A `start_session` call's arguments, validated.
nonisolated struct StartSessionRequest: Equatable {
    enum Initiation: String, CaseIterable {
        case userAsked = "user_asked"
        case ownInitiative = "own_initiative"
        case offer
    }

    enum Context: String, CaseIterable {
        case fresh
        /// The child resumes a copy of the parent's whole conversation.
        case fork
    }

    static let titleLimit = 60
    static let nameLimit = 24
    static let minimumBackground = 80

    var title: String
    var prompt: String
    var initiation: Initiation
    var name: String?
    var background: String?
    var context: Context = .fresh
    /// Nil follows the parent: a worktree when the parent works in one.
    var useWorktree: Bool?
    var model: AgentModel?
    var effort: AgentEffort?
    var permissionMode: PermissionMode?
    var wakeWhenDone = true

    static func parse(_ arguments: [String: JSONValue]) -> Result<StartSessionRequest, ChildSessionError> {
        func text(_ key: String) -> String? {
            guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            return value
        }
        guard let title = text("title") else { return .failure(.invalid("title is required")) }
        guard title.count < titleLimit else {
            return .failure(.invalid("title must be under \(titleLimit) characters"))
        }
        guard let prompt = text("prompt") else { return .failure(.invalid("prompt is required")) }
        guard let initiationRaw = text("initiation") else { return .failure(.invalid("initiation is required")) }
        guard let initiation = Initiation(rawValue: initiationRaw) else {
            return .failure(.invalid("initiation must be one of \(Initiation.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        var request = StartSessionRequest(title: title, prompt: prompt, initiation: initiation)

        if let name = text("name") {
            guard name.count <= nameLimit, name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
            else {
                return .failure(.invalid("name must be at most \(nameLimit) characters of a-z, 0-9 and -"))
            }
            request.name = name
        }
        if let raw = text("context") {
            guard let context = Context(rawValue: raw) else {
                return .failure(.invalid("context must be fresh or fork"))
            }
            request.context = context
        }
        if let background = text("background"), request.context == .fresh {
            guard background.count >= minimumBackground else {
                return .failure(.invalid("background must be at least \(minimumBackground) characters, so the new session has what it needs from this conversation"))
            }
            request.background = background
        }
        request.useWorktree = arguments["use_worktree"]?.boolValue
        if let raw = text("model") {
            guard let model = AgentModel.recognizing(raw, provider: .claudeCode) else {
                return .failure(.invalid("unknown model \(raw)"))
            }
            request.model = model
        }
        if let raw = text("effort") {
            let known = AgentProviderKind.claudeCode.efforts
            guard let effort = AgentEffort.recognizing(raw), known.contains(effort) else {
                return .failure(.invalid("effort must be one of \(known.map(\.token).joined(separator: ", "))"))
            }
            request.effort = effort
        }
        if let raw = text("permission_mode") {
            guard let mode = PermissionMode.recognizing(raw) else {
                return .failure(.invalid("permission_mode must be one of \(PermissionMode.allCases.map(\.token).joined(separator: ", "))"))
            }
            request.permissionMode = mode
        }
        request.wakeWhenDone = arguments["wake_when_done"]?.boolValue ?? true
        return .success(request)
    }

    /// What the sidebar and the notes call the child.
    var displayName: String { name ?? title }
}

nonisolated enum ChildSessionError: Error, Equatable {
    case invalid(String)
    /// `own_initiative` and `offer`, until proposals exist (PLUME-419).
    case proposalsUnsupported
    case unknownSession(String)
    case notRelated(String)
    case parentClosed
    case failed(String)

    var message: String {
        switch self {
        case .invalid(let detail): detail
        case .proposalsUnsupported:
            "Only initiation \"user_asked\" is supported: proposals arrive in a later version. Start a session only when the user asks for one."
        case .unknownSession(let id): "No session with id \(id)."
        case .notRelated(let id): "Session \(id) is neither the session that started this one nor one this session started."
        case .parentClosed: "This session's tab is closed."
        case .failed(let detail): detail
        }
    }
}
