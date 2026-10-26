import Foundation

/// The Plume tab or task a command runs in, from `PLUME_TAB_ID`, else
/// `PLUME_TASK_ID`.
nonisolated enum PlumeCaller: Equatable, Sendable {
    /// The tab rather than its task, since a moved tab keeps its ID but not
    /// its task.
    case tab(UUID)
    case task(UUID)

    static func from(environment: [String: String]) -> PlumeCaller? {
        // TODO(PLUME-316 group D)
        nil
    }
}

/// The app actions `wt` asks for over the CLI socket. Each answers whether
/// the app did it; an unreachable app is a false, never a throw.
nonisolated protocol PlumeAppClient: AnyObject {
    /// A terminal tab at `directory` in the caller's task (`tab.new`).
    func openTab(directory: String, caller: PlumeCaller) -> Bool
    /// A new task for the worktree at `worktreePath`, in the caller's group
    /// (`task.new`). The app reads the repository and branch from the
    /// worktree.
    func openTask(worktreePath: String, caller: PlumeCaller) -> Bool
}

/// `PlumeAppClient` over the socket at `socketPath`.
nonisolated final class SocketPlumeAppClient: PlumeAppClient {
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func openTab(directory: String, caller: PlumeCaller) -> Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func openTask(worktreePath: String, caller: PlumeCaller) -> Bool {
        // TODO(PLUME-316 group D, after the app serves `task.new`)
        false
    }
}

/// Opens a worktree somewhere the user can work in it. Best effort: a failure
/// to open is never fatal to the command that asked.
nonisolated protocol TabOpener: AnyObject {
    /// Whether this process runs inside a Plume tab or task, so a tab can be
    /// requested at all. `wt switch` opens a tab only when this holds.
    var canOpenTabs: Bool { get }
    /// A tab in the calling task, or with `asTask` a new task. Anywhere it
    /// can't, prints the `cd` hint instead.
    func open(_ directory: String, asTask: Bool)
}

/// Opens tabs through the running app. Outside Plume, or when the app
/// refuses or can't be reached, it prints `wt: <dir>` and `wt: (cd "<dir>")`.
/// A failed tab request never escalates to a task.
nonisolated final class PlumeTabOpener: TabOpener {
    let client: any PlumeAppClient
    let environment: [String: String]
    let console: any CLIConsole

    init(client: any PlumeAppClient, environment: [String: String], console: any CLIConsole) {
        self.client = client
        self.environment = environment
        self.console = console
    }

    var canOpenTabs: Bool {
        // TODO(PLUME-316 group D)
        false
    }

    func open(_ directory: String, asTask: Bool) {
        // TODO(PLUME-316 group D)
    }
}
