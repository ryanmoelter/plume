import Foundation

/// Status of an agent tab, and (aggregated) of a task.
enum TaskStatus: String, CaseIterable, Sendable {
    case unset
    case idle
    case working
    case needsInput
    case done
    /// Stopped mid-turn because the user said so. Distinct from `done`, which
    /// claims the work finished, and from `error`, which blames the agent.
    case interrupted
    case error

    /// Higher wins when aggregating tab statuses into a task status.
    var priority: Int {
        switch self {
        case .unset: 0
        case .idle: 1
        case .done: 2
        case .interrupted: 3
        case .error: 4
        case .working: 5
        case .needsInput: 6
        }
    }

    static func aggregate(_ statuses: some Sequence<TaskStatus>) -> TaskStatus {
        statuses.max { $0.priority < $1.priority } ?? .unset
    }
}

enum TabKind: String, CaseIterable, Sendable {
    case agent
    case terminal
}

/// How an agent tab talks to `claude`. `headless` drives `claude -p` over
/// stream-json and always renders as chat; `terminal` keeps the PTY/TUI as
/// the escape hatch and always renders as a terminal.
enum AgentTransport: String, CaseIterable, Sendable {
    case headless
    case terminal
}

enum WorkspaceKind: String, CaseIterable, Sendable {
    case unset
    case directory
    case worktree
}
