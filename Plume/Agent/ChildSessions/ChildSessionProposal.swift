import Foundation
import os

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
    /// For a fork, where the parent's conversation stood when it was
    /// proposed: the row before the `start_session` call, for
    /// `--resume-session-at`. Nil forks the conversation as it is at the start.
    var forkCut: String?
    var createdAt: Date
    var status: Status = .pending
    /// When it was started or dismissed.
    var settledAt: Date?
    /// The child's session id: its tab's UUID.
    var startedSessionID: String?
    var startedName: String?
    var dismissReason: String?
    var dismissedByUser: Bool?

    init(id: String, request: StartSessionRequest, createdAt: Date, forkCut: String? = nil) {
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
        self.forkCut = request.context == .fork ? forkCut : nil
        self.createdAt = createdAt
    }

    var expiresAt: Date { createdAt.addingTimeInterval(ChildSessionProposalStore.lifetime) }

    func isExpired(at now: Date) -> Bool {
        status == .pending && now >= expiresAt
    }

    /// When it stopped being startable.
    fileprivate var settledDate: Date { settledAt ?? expiresAt }

    /// The request that starts it, exactly as proposed.
    func request(wakeWhenDone override: Bool? = nil) -> Result<StartSessionRequest, ChildSessionError> {
        StartSessionRequest.parse(arguments(wakeWhenDone: override))
    }

    /// Why a start by `proposal_id` that repeated part of the brief or the
    /// launch settings is refused: what it repeated differs from the
    /// proposal's own. Nil when it all matches.
    func conflict(with repeated: [String: JSONValue]) -> ChildSessionError? {
        guard !repeated.isEmpty else { return nil }
        let differing: [String]
        if case .success(let proposed) = request(),
           case .success(let asked) = StartSessionRequest.parse(arguments().merging(repeated) { $1 }) {
            let fields: [(String, Bool)] = [
                ("title", asked.title == proposed.title),
                ("prompt", asked.prompt == proposed.prompt),
                ("name", asked.name == proposed.name),
                ("background", asked.background == proposed.background),
                ("model", asked.model == proposed.model),
                ("effort", asked.effort == proposed.effort),
                ("permission_mode", asked.permissionMode == proposed.permissionMode),
                ("use_worktree", asked.useWorktree == proposed.useWorktree),
                ("context", asked.context == proposed.context)
            ]
            differing = fields.filter { !$0.1 && repeated[$0.0] != nil }.map(\.0)
        } else {
            differing = repeated.keys.sorted()
        }
        guard !differing.isEmpty else { return nil }
        let brief: Set<String> = ["title", "prompt", "name", "background"]
        let advice = differing.contains(where: brief.contains)
            ? "To change the brief, dismiss_task it and start a new session, or start it as it is and send_message the child once it starts."
            : "To change them, dismiss_task it and start a new session."
        return .invalid("proposal_id starts the proposal with its own brief and settings, and \(differing.joined(separator: ", ")) differs from them. \(advice)")
    }

    private func arguments(wakeWhenDone override: Bool? = nil) -> [String: JSONValue] {
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
        return arguments
    }
}

/// One parent tab's proposals, persisted as JSON in
/// `TaskTab.childProposalsJSON`. Pure, so the rules test without SwiftData.
nonisolated struct ChildSessionProposalStore: Equatable {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    /// How many started, dismissed or expired proposals a tab keeps, newest
    /// first, so their cards keep reading as settled.
    static let settledLimit = 200

    private(set) var proposals: [ChildSessionProposal]
    /// Entries this build cannot decode, as a newer one may have written
    /// them. Every write carries them through unchanged.
    private(set) var unreadable: [JSONValue] = []
    /// Stored text that is not a JSON array at all. While set, the store
    /// must not be written, or that text would be lost.
    private(set) var unreadableText: String?
    /// Keys a newer build added to an entry this build reads, by proposal
    /// id. Every write carries them through unchanged.
    private var unknownKeys: [String: [String: JSONValue]] = [:]

    init(proposals: [ChildSessionProposal] = []) {
        self.proposals = proposals
    }

    init(json: String) {
        proposals = []
        guard !json.isEmpty else { return }
        guard let entries = try? JSONDecoder().decode([JSONValue].self, from: Data(json.utf8)) else {
            unreadableText = json
            Log.agent.error("Child session proposals are not a JSON array; leaving them as stored")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for entry in entries {
            if let data = try? JSONEncoder().encode(entry),
               let proposal = try? decoder.decode(ChildSessionProposal.self, from: data) {
                proposals.append(proposal)
                if case .object(let stored) = entry, let known = Self.encoded(proposal) {
                    let unknown = stored.filter { known[$0.key] == nil }
                    if !unknown.isEmpty { unknownKeys[proposal.id] = unknown }
                }
            } else {
                unreadable.append(entry)
            }
        }
        let unreadableCount = unreadable.count
        if unreadableCount > 0 {
            Log.agent.error("Carrying \(unreadableCount, privacy: .public) child session proposals this build cannot read")
        }
    }

    /// False when the stored text could not be read at all.
    var isWritable: Bool { unreadableText == nil }

    var json: String {
        if let unreadableText { return unreadableText }
        guard !proposals.isEmpty || !unreadable.isEmpty else { return "" }
        let decoded = proposals.compactMap { proposal in
            Self.encoded(proposal).map { JSONValue.object((unknownKeys[proposal.id] ?? [:]).merging($0) { $1 }) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(decoded + unreadable)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func encoded(_ proposal: ChildSessionProposal) -> [String: JSONValue]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(proposal),
              case .object(let fields) = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return fields
    }

    static func makeID(random: UInt32 = .random(in: .min ... .max)) -> String {
        "task_" + String(format: "%08x", random)
    }

    func proposal(id: String) -> ChildSessionProposal? {
        proposals.first { $0.id == id }
    }

    /// Keeps every proposal that can still start, and the newest
    /// `settledLimit` of the rest.
    mutating func prune(now: Date) {
        let settled = proposals
            .filter { $0.status != .pending || $0.isExpired(at: now) }
            .sorted { $0.settledDate > $1.settledDate }
        guard settled.count > Self.settledLimit else { return }
        let dropped = Set(settled[Self.settledLimit...].map(\.id))
        proposals.removeAll { dropped.contains($0.id) }
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

    /// Records the start whatever the proposal's age, since the caller
    /// already found it pending. False only when the store has no such
    /// proposal.
    @discardableResult
    mutating func markStarted(id: String, sessionID: String, name: String, now: Date) -> Bool {
        guard var proposal = proposal(id: id) else { return false }
        proposal.status = .started
        proposal.settledAt = now
        proposal.startedSessionID = sessionID
        proposal.startedName = name
        replace(proposal)
        return true
    }

    /// Undoes `markStarted` for a launch that failed after recording it.
    mutating func reopen(id: String) {
        guard var proposal = proposal(id: id), proposal.status == .started else { return }
        proposal.status = .pending
        proposal.settledAt = nil
        proposal.startedSessionID = nil
        proposal.startedName = nil
        replace(proposal)
    }

    /// What `id`'s card shows. A proposal this store doesn't hold was made
    /// in another session, or fell past `settledLimit`.
    func cardState(id: String, now: Date) -> ChildSessionProposalCardState {
        guard let proposal = proposal(id: id) else { return .elsewhere }
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
    /// The chat shows a proposal its tab doesn't own: a copied transcript, or
    /// a child whose parent has closed.
    case elsewhere
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
            "No proposal with task_id \(id) in this session. Propose it again if it is still worth doing."
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

/// How a `start_session` call reads: a start, a proposal, an offer, or the
/// start of an earlier proposal.
nonisolated enum StartSessionCall: Equatable {
    case start(StartSessionRequest)
    case propose(StartSessionRequest)
    /// Asks the user, on a card, whether to start it or have the agent do it.
    case offer(StartSessionRequest)
    /// `settings` are the brief and launch settings the call repeated, which
    /// must match the proposal's own.
    case startProposal(id: String, wakeWhenDone: Bool?, settings: [String: JSONValue])

    /// What a start by `proposal_id` may repeat, as long as it matches.
    static let repeatable: Set<String> = [
        "title", "prompt", "name", "background", "model", "effort", "permission_mode", "use_worktree", "context"
    ]

    static func parse(_ arguments: [String: JSONValue]) -> Result<StartSessionCall, ChildSessionError> {
        if hasProposalID(arguments) {
            guard let id = arguments["proposal_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .failure(.invalid("proposal_id must be the task_id a proposal returned"))
            }
            let extra = Set(arguments.keys)
                .subtracting(["proposal_id", "wake_when_done", "initiation"])
                .subtracting(repeatable)
            guard extra.isEmpty else {
                return .failure(.invalid("proposal_id does not take \(extra.sorted().joined(separator: ", "))."))
            }
            return .success(.startProposal(
                id: id,
                wakeWhenDone: arguments["wake_when_done"]?.boolValue,
                settings: arguments.filter { repeatable.contains($0.key) && !isBlank($0.value) }
            ))
        }
        return StartSessionRequest.parse(arguments).map { request in
            switch request.initiation {
            case .userAsked: .start(request)
            case .ownInitiative: .propose(request)
            case .offer: .offer(request)
            }
        }
    }

    /// A `null` or blank `proposal_id` counts as absent.
    private static func hasProposalID(_ arguments: [String: JSONValue]) -> Bool {
        arguments["proposal_id"].map { !isBlank($0) } ?? false
    }

    /// A `null` or blank value counts as not sent.
    private static func isBlank(_ value: JSONValue) -> Bool {
        switch value {
        case .null: true
        case .string(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// Whether the call only shows a card, a proposal's or an offer's, so it
    /// starts nothing without the user. Manual mode allows it.
    static func isProposal(_ arguments: [String: JSONValue]) -> Bool {
        guard let initiation = cardInitiation(arguments) else { return false }
        return initiation != .userAsked
    }

    /// Whether the call raises an offer card, which plan mode refuses because
    /// the user can start the session from it.
    static func isOffer(_ arguments: [String: JSONValue]) -> Bool {
        cardInitiation(arguments) == .offer
    }

    /// The call's recognized initiation, unless it starts a proposal by id.
    private static func cardInitiation(_ arguments: [String: JSONValue]) -> StartSessionRequest.Initiation? {
        guard !hasProposalID(arguments),
              let raw = arguments["initiation"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return StartSessionRequest.Initiation(rawValue: raw)
    }
}
