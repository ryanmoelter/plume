import Foundation

/// Status of an agent tab, and (aggregated) of a task.
///
/// The vocabulary is working or not working, and every not-working state that
/// wants the user names what it wants. There is no general "needs attention":
/// a summons that cannot say why is worse than none, so the only unnamed one
/// is `needsTerminalInput`, which exists because the terminal transport's hook
/// genuinely cannot say more.
enum TaskStatus: String, CaseIterable, Sendable {
    /// No agent has run, or none is running after a relaunch. Distinct from
    /// `awaitingReply`, which claims a turn actually ended.
    case notStarted
    case working
    /// The one resting state: the agent's turn is over and it is the user's
    /// move. Covers a finished turn and a cleanly exited process alike, which
    /// read the same to someone scanning the sidebar.
    case awaitingReply
    /// Finished for good, with no one expected to reply. Only a subagent
    /// reaches this: it is spawned to do one thing and then it is over. An
    /// agent tab never does — a turn ending hands the conversation back to the
    /// user, and calling that "done" would claim a decision only the user can
    /// make by archiving the task.
    case done
    case planApproval
    case questionAsked
    case permissionNeeded
    /// The terminal transport wants the user but cannot say why: its hook
    /// reports only that Claude Code asked for someone.
    case needsTerminalInput
    /// Stopped mid-turn because the user said so. Distinct from
    /// `awaitingReply`, which claims the work reached an end, and from
    /// `error`, which blames the agent.
    case interrupted
    case error

    /// Higher wins when aggregating tab statuses into a task status. Every
    /// state that wants the user outranks `working`, because a tab stalled on
    /// a question is more worth surfacing than one still busy. Among those,
    /// the more consequential the answer, the higher — and an unnamed summons
    /// ranks below every named one, so a tie shows the reason it can state.
    var priority: Int {
        switch self {
        case .notStarted: 0
        case .done: 1
        case .awaitingReply: 2
        case .interrupted: 3
        case .error: 4
        case .working: 5
        case .needsTerminalInput: 6
        case .permissionNeeded: 7
        case .questionAsked: 8
        case .planApproval: 9
        }
    }

    /// Whether the agent has stopped and wants a specific answer.
    var wantsAttention: Bool {
        switch self {
        case .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput:
            true
        case .notStarted, .working, .awaitingReply, .done, .interrupted, .error:
            false
        }
    }

    /// How a snapshot of this status reads once the app has restarted.
    ///
    /// Quitting kills every agent, so a status that claimed something was
    /// happening is describing a process that no longer exists. What survives
    /// is whether the work reached an end:
    ///
    /// - `interrupted`, `error` and `done` already describe an outcome rather
    ///   than a process, so they stay as they are.
    /// - A tab that was waiting on an answer never got one, and quitting is
    ///   what stopped it. That is an interruption, so it reads as one — the
    ///   question or plan is still there in the transcript, unanswered.
    /// - `working` and `awaitingReply` claimed a live process and say nothing
    ///   that outlives it, so they read as `notStarted`.
    var afterRelaunch: TaskStatus {
        switch self {
        case .interrupted, .error, .done: self
        case .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput: .interrupted
        case .notStarted, .working, .awaitingReply: .notStarted
        }
    }

    static func aggregate(_ statuses: some Sequence<TaskStatus>) -> TaskStatus {
        statuses.max { $0.priority < $1.priority } ?? .notStarted
    }

    /// Reads a snapshot written before the vocabulary was split, so an
    /// existing store keeps its meaning.
    ///
    /// A persisted `needsInput` becomes `needsTerminalInput` whatever the
    /// transport: the reason lived only in the running session, so a snapshot
    /// can say that the agent wanted the user but never why.
    init(migratingRawValue raw: String) {
        if let known = TaskStatus(rawValue: raw) {
            self = known
            return
        }
        switch raw {
        case "unset": self = .notStarted
        case "idle": self = .awaitingReply
        case "needsInput": self = .needsTerminalInput
        default: self = .notStarted
        }
    }
}

enum TabKind: String, CaseIterable, Sendable {
    case agent
    case terminal
}

/// Which coding-agent CLI an agent tab runs. Orthogonal to `AgentTransport`,
/// which picks how Plume talks to it.
enum AgentProviderKind: String, CaseIterable, Sendable, Identifiable {
    case claudeCode = "claude-code"
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Transports this CLI can run on. Codex has no headless client yet, so a
    /// Codex tab opens as a TUI whatever the app default says.
    var supportedTransports: [AgentTransport] {
        switch self {
        case .claudeCode: AgentTransport.allCases
        case .codex: [.terminal]
        }
    }

    func resolvedTransport(preferring preferred: AgentTransport) -> AgentTransport {
        supportedTransports.contains(preferred) ? preferred : supportedTransports[0]
    }
}

/// How an agent tab talks to its CLI. `headless` drives it over a JSON
/// protocol on pipes and always renders as chat; `terminal` keeps the PTY/TUI
/// as the escape hatch and always renders as a terminal.
enum AgentTransport: String, CaseIterable, Sendable {
    case headless
    case terminal
}

enum WorkspaceKind: String, CaseIterable, Sendable {
    case unset
    case directory
    case worktree
}
