import Foundation

/// A session an agent proposed with `start_session` and
/// `initiation: "own_initiative"`. Nothing runs until the user starts it from
/// its card, or tells the agent to start it by `proposal_id`.
nonisolated struct ChildSessionProposal: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case pending
        case started
        case dismissed
    }

    /// The task_id the model sees: `task_` and 8 hex digits.
    let id: String
    var title: String
    var prompt: String
    var name: String?
    var background: String?
    var context: String?
    var useWorktree: Bool?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var wakeWhenDone: Bool?
    var createdAt: Date
    var status: Status = .pending
    /// When it was started or dismissed.
    var settledAt: Date?
    /// The child's session id: its tab's UUID.
    var startedSessionID: String?
    var startedName: String?
    var dismissReason: String?
    var dismissedByUser: Bool?

    init(id: String, request: StartSessionRequest, createdAt: Date) {
        self.id = id
        title = request.title
        prompt = request.prompt
        name = request.name
        background = request.background
        context = request.context.rawValue
        useWorktree = request.useWorktree
        model = request.model?.token
        effort = request.effort?.token
        permissionMode = request.permissionMode?.token
        wakeWhenDone = request.wakeWhenDone ? nil : false
        self.createdAt = createdAt
    }

    func isExpired(at now: Date) -> Bool {
        status == .pending && now >= createdAt.addingTimeInterval(ChildSessionProposalStore.lifetime)
    }

    /// The request that starts it, exactly as proposed.
    func request(wakeWhenDone override: Bool? = nil) -> Result<StartSessionRequest, ChildSessionError> {
        var arguments: [String: JSONValue] = [
            "title": .string(title),
            "prompt": .string(prompt),
            "initiation": .string(StartSessionRequest.Initiation.userAsked.rawValue)
        ]
        for (key, value) in [
            ("name", name), ("background", background), ("context", context),
            ("model", model), ("effort", effort), ("permission_mode", permissionMode)
        ] {
            if let value { arguments[key] = .string(value) }
        }
        if let useWorktree { arguments["use_worktree"] = .bool(useWorktree) }
        if let wake = override ?? wakeWhenDone { arguments["wake_when_done"] = .bool(wake) }
        return StartSessionRequest.parse(arguments)
    }
}

/// One parent tab's proposals, persisted as JSON in
/// `TaskTab.childProposalsJSON`. Pure, so the rules test without SwiftData.
nonisolated struct ChildSessionProposalStore: Equatable {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    /// How long a started or dismissed proposal stays, so its card keeps
    /// reading as started or dismissed.
    static let settledRetention: TimeInterval = 30 * 24 * 60 * 60

    private(set) var proposals: [ChildSessionProposal]

    init(proposals: [ChildSessionProposal] = []) {
        self.proposals = proposals
    }

    /// Empty or unreadable JSON is an empty store.
    init(json: String) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        proposals = (try? decoder.decode([ChildSessionProposal].self, from: Data(json.utf8))) ?? []
    }

    var json: String {
        guard !proposals.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(proposals)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func makeID(random: UInt32 = .random(in: .min ... .max)) -> String {
        "task_" + String(format: "%08x", random)
    }

    func proposal(id: String) -> ChildSessionProposal? {
        proposals.first { $0.id == id }
    }

    /// Drops pending proposals past their lifetime, and settled ones past
    /// `settledRetention`.
    mutating func prune(now: Date) {
        proposals.removeAll { proposal in
            if proposal.isExpired(at: now) { return true }
            guard let settledAt = proposal.settledAt else { return false }
            return now >= settledAt.addingTimeInterval(Self.settledRetention)
        }
    }

    mutating func add(_ proposal: ChildSessionProposal) {
        proposals.removeAll { $0.id == proposal.id }
        proposals.append(proposal)
    }

    /// The proposal `id` names, if it can still start.
    func pending(id: String, now: Date) -> Result<ChildSessionProposal, ChildSessionProposalError> {
        guard let proposal = proposal(id: id) else { return .failure(.unknown(id)) }
        switch proposal.status {
        case .started: return .failure(.started(id, sessionID: proposal.startedSessionID ?? ""))
        case .dismissed: return .failure(.dismissed(id))
        case .pending: break
        }
        guard !proposal.isExpired(at: now) else { return .failure(.expired(id)) }
        return .success(proposal)
    }

    mutating func dismiss(id: String, reason: String?, byUser: Bool, now: Date) -> Result<ChildSessionProposal, ChildSessionProposalError> {
        switch pending(id: id, now: now) {
        case .failure(let error): return .failure(error)
        case .success(var proposal):
            proposal.status = .dismissed
            proposal.settledAt = now
            proposal.dismissReason = reason
            proposal.dismissedByUser = byUser
            replace(proposal)
            return .success(proposal)
        }
    }

    mutating func markStarted(id: String, sessionID: String, name: String, now: Date) {
        guard var proposal = proposal(id: id) else { return }
        proposal.status = .started
        proposal.settledAt = now
        proposal.startedSessionID = sessionID
        proposal.startedName = name
        replace(proposal)
    }

    /// What `id`'s card shows. A proposal the store no longer holds has
    /// outlived its lifetime.
    func cardState(id: String, now: Date) -> ChildSessionProposalCardState {
        guard let proposal = proposal(id: id) else { return .expired }
        switch proposal.status {
        case .started: return .started(sessionID: proposal.startedSessionID ?? "", name: proposal.startedName ?? proposal.title)
        case .dismissed: return .dismissed
        case .pending: return proposal.isExpired(at: now) ? .expired : .pending
        }
    }

    private mutating func replace(_ proposal: ChildSessionProposal) {
        guard let index = proposals.firstIndex(where: { $0.id == proposal.id }) else { return }
        proposals[index] = proposal
    }
}

nonisolated enum ChildSessionProposalCardState: Equatable {
    case pending
    case started(sessionID: String, name: String)
    case dismissed
    case expired
}

nonisolated enum ChildSessionProposalError: Error, Equatable {
    case unknown(String)
    case expired(String)
    case dismissed(String)
    case started(String, sessionID: String)
    /// A start for it is already under way.
    case starting(String)

    var message: String {
        switch self {
        case .unknown(let id):
            "No proposal with task_id \(id). Proposals expire after 7 days; propose it again if it is still worth doing."
        case .expired(let id):
            "Proposal \(id) expired: proposals last 7 days. Propose it again if it is still worth doing."
        case .dismissed(let id):
            "Proposal \(id) was dismissed, so it cannot start. Propose it again, or start a new session if the user asks for one."
        case .started(let id, let sessionID):
            "Proposal \(id) already started as session \(sessionID). Message it with mcp__plume__send_message instead."
        case .starting(let id):
            "Proposal \(id) is already starting."
        }
    }
}

/// How a `start_session` call reads: a start, a proposal, or the start of an
/// earlier proposal.
nonisolated enum StartSessionCall: Equatable {
    case start(StartSessionRequest)
    case propose(StartSessionRequest)
    case startProposal(id: String, wakeWhenDone: Bool?)

    static func parse(_ arguments: [String: JSONValue]) -> Result<StartSessionCall, ChildSessionError> {
        if let raw = arguments["proposal_id"] {
            guard let id = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return .failure(.invalid("proposal_id must be the task_id a proposal returned"))
            }
            let extra = Set(arguments.keys).subtracting(["proposal_id", "wake_when_done"])
            guard extra.isEmpty else {
                return .failure(.invalid("proposal_id starts a proposal exactly as proposed, so it takes nothing else (wake_when_done aside). To change it, dismiss_task it and start a new session."))
            }
            return .success(.startProposal(id: id, wakeWhenDone: arguments["wake_when_done"]?.boolValue))
        }
        return StartSessionRequest.parse(arguments).map { request in
            request.initiation == .userAsked ? .start(request) : .propose(request)
        }
    }

    /// Whether the call only records a card, which plan mode allows.
    static func isProposal(_ arguments: [String: JSONValue]) -> Bool {
        guard arguments["proposal_id"] == nil,
              let raw = arguments["initiation"]?.stringValue,
              let initiation = StartSessionRequest.Initiation(rawValue: raw)
        else { return false }
        return initiation != .userAsked
    }
}
