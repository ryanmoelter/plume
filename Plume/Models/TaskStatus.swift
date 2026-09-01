import Foundation

/// Status of an agent tab, and (aggregated) of a task.
enum TaskStatus: String, CaseIterable, Sendable {
    case unset
    case idle
    case working
    case needsInput
    case done
    case error

    /// Higher wins when aggregating tab statuses into a task status.
    var priority: Int {
        switch self {
        case .unset: 0
        case .idle: 1
        case .done: 2
        case .error: 3
        case .working: 4
        case .needsInput: 5
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

/// Which view an agent tab presents. Both stay mounted, so switching never
/// touches the running process — see `TabContentView`.
enum TabRenderMode: String, CaseIterable, Sendable {
    case chat
    case terminal
}

enum WorkspaceKind: String, CaseIterable, Sendable {
    case unset
    case directory
    case worktree
}
