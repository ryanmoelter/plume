import Foundation

/// The Plume tab or task a command runs in, from `PLUME_TAB_ID`, else
/// `PLUME_TASK_ID`.
nonisolated enum PlumeCaller: Equatable, Sendable {
    /// The tab rather than its task, since a moved tab keeps its ID but not
    /// its task.
    case tab(UUID)
    case task(UUID)

    static func from(environment: [String: String]) -> PlumeCaller? {
        if let tabID = environment[CLISocket.tabIDEnvironmentKey].flatMap(UUID.init(uuidString:)) {
            return .tab(tabID)
        }
        if let taskID = environment[CLISocket.taskIDEnvironmentKey].flatMap(UUID.init(uuidString:)) {
            return .task(taskID)
        }
        return nil
    }

    var tabID: UUID? {
        if case .tab(let id) = self { id } else { nil }
    }

    var taskID: UUID? {
        if case .task(let id) = self { id } else { nil }
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
    /// The Settings window on `section` (`settings.open`). Needs no caller.
    func openSettings(section: String?) -> Bool
}

nonisolated extension PlumeAppClient {
    func openSettings(section: String?) -> Bool { false }
}

/// `PlumeAppClient` over the socket at `socketPath`. A nil path means no
/// app is reachable, so every request fails.
nonisolated final class SocketPlumeAppClient: PlumeAppClient {
    let socketPath: String?

    init(socketPath: String?) {
        self.socketPath = socketPath
    }

    /// Every request changes the app, which answers on its main queue — late
    /// when busy, and `task.new` only after git.
    static let replyTimeout: TimeInterval = 30

    private func succeeds(_ request: CLIRequest) -> Bool {
        guard let socketPath, !socketPath.isEmpty else { return false }
        return (try? CLISocket.send(request, to: socketPath, replyTimeout: Self.replyTimeout))?.ok == true
    }

    func openTab(directory: String, caller: PlumeCaller) -> Bool {
        succeeds(.newTab(.init(taskID: caller.taskID, tabID: caller.tabID, directory: directory, select: false)))
    }

    func openTask(worktreePath: String, caller: PlumeCaller) -> Bool {
        succeeds(.newTask(.init(worktreePath: worktreePath, taskID: caller.taskID, tabID: caller.tabID, select: false)))
    }

    func openSettings(section: String?) -> Bool {
        succeeds(.openSettings(.init(section: section)))
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
    /// Asks the running app to show Settings on `section`; false when it is
    /// unreachable or refuses.
    func openSettings(section: String?) -> Bool
}

nonisolated extension TabOpener {
    func openSettings(section: String?) -> Bool { false }
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

    private var caller: PlumeCaller? {
        PlumeCaller.from(environment: environment)
    }

    var canOpenTabs: Bool {
        caller != nil
    }

    func open(_ directory: String, asTask: Bool) {
        if let caller {
            let opened = asTask
                ? client.openTask(worktreePath: directory, caller: caller)
                : client.openTab(directory: directory, caller: caller)
            if opened { return }
        }
        console.print("\(WT.programName): \(directory)")
        console.print("\(WT.programName): (cd \"\(directory)\")")
    }

    func openSettings(section: String?) -> Bool {
        client.openSettings(section: section)
    }
}
