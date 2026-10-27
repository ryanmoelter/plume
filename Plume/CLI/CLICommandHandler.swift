import AppKit
import Foundation
import SwiftData

/// Answers the requests `CLIServer` receives.
@MainActor
final class CLICommandHandler {
    static let shared = CLICommandHandler()

    /// What an open main window offers a request. `MainWindow` registers one
    /// per window, keeping SwiftData queries out of here.
    struct WindowRegistration {
        /// Nil until the view finds its window.
        var window: () -> NSWindow?
        var task: (UUID) -> WorkTask?
        var taskIDForTab: (UUID) -> UUID?
        var context: ModelContext
        /// Shows the task in this window, for `tab new --select`.
        var reveal: (UUID) -> Void
        var openSettings: () -> Void = {}
    }

    /// A checkout `task.new` opens: which project it belongs to, and its
    /// branch, nil when detached.
    nonisolated struct Checkout: Sendable {
        var facts: CheckoutFacts
        var branch: String?
    }

    /// Most recently registered last.
    private var registrations: [(id: UUID, registration: WindowRegistration)] = []

    var orderedWindows: () -> [NSWindow] = { NSApp.orderedWindows }
    var directories: TabDirectoryStore = .shared

    func registerWindow(_ id: UUID, _ registration: WindowRegistration) {
        unregisterWindow(id)
        registrations.append((id, registration))
    }

    func unregisterWindow(_ id: UUID) {
        registrations.removeAll { $0.id == id }
    }

    /// By screen order, then by most recent registration for a window not on
    /// screen yet.
    private var frontmostFirst: [WindowRegistration] {
        let screenOrder = orderedWindows()
        let byRecency = registrations.reversed().map(\.registration)
        return byRecency.enumerated().sorted { lhs, rhs in
            let left = lhs.element.window().flatMap { window in screenOrder.firstIndex { $0 === window } } ?? .max
            let right = rhs.element.window().flatMap { window in screenOrder.firstIndex { $0 === window } } ?? .max
            return (left, lhs.offset) < (right, rhs.offset)
        }.map(\.element)
    }

    var notify: (_ tabID: UUID, _ title: String, _ body: String) -> Bool = { tabID, title, body in
        TerminalAlerts.shared.notify(tabID: tabID, title: title, body: body)
    }

    var inspectCheckout: @Sendable (String) async -> Checkout? = { path in
        guard let facts = await GitService.shared.checkoutFacts(containing: path) else { return nil }
        let branch = await GitService.shared.currentBranch(in: path)
        return Checkout(facts: facts, branch: branch == "HEAD" ? nil : branch)
    }

    /// Where `SettingsView` keeps its selected pane.
    var settingsDefaults: UserDefaults = .standard
    var activateApp: () -> Void = { NSApp.activate() }

    func handle(_ request: CLIRequest) async -> CLIResponse {
        switch request {
        case .ping:
            var response = CLIResponse.success
            response.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            return response
        case .notify(let params):
            guard notify(params.tabID, params.title, params.body) else {
                return .failure("no Plume tab \(params.tabID.uuidString)")
            }
            return .success
        case .newTab(let params):
            return newTab(params)
        case .newTask(let params):
            return await newTask(params)
        case .openSettings(let params):
            return openSettings(params)
        }
    }

    /// The worktree already exists, since `wt` made it; this only opens a
    /// task on it. An unknown caller puts the task outside any group rather
    /// than failing, because the worktree is there either way.
    private func newTask(_ params: CLIRequest.NewTask) async -> CLIResponse {
        let path = params.worktreePath
        guard path.hasPrefix("/") else {
            return .failure("worktreePath must be an absolute path: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("no such directory: \(path)")
        }
        guard let checkout = await inspectCheckout(path),
              Self.resolvedPath(checkout.facts.checkoutRoot) == Self.resolvedPath(path)
        else { return .failure("not a git worktree: \(path)") }

        let windows = frontmostFirst
        let callerTaskID = params.taskID ?? params.tabID.flatMap { tabID in
            windows.lazy.compactMap { $0.taskIDForTab(tabID) }.first
        }
        let caller = callerTaskID.flatMap { id in
            windows.lazy.compactMap { window in window.task(id).map { (task: $0, context: window.context) } }.first
        }
        guard let context = caller?.context ?? windows.first?.context else {
            return .failure("no Plume window is open")
        }
        let liveTasks = ((try? context.fetch(FetchDescriptor<WorkTask>())) ?? []).filter { !$0.isArchived }
        // A client that timed out and retried would otherwise get a second
        // task for the same worktree.
        let resolved = Self.resolvedPath(path)
        if let existing = liveTasks.first(where: { $0.workingDirectoryPath.map(Self.resolvedPath) == resolved }) {
            if params.select { windows.first?.reveal(existing.id) }
            var response = CLIResponse.success
            response.taskID = existing.id
            return response
        }
        let group = caller?.task.group
        let siblings = liveTasks.filter { $0.group?.id == group?.id }
        let task = TaskStore.createTask(
            in: context, title: (path as NSString).lastPathComponent, group: group, siblings: siblings
        )
        task.workingDirectoryPath = path
        task.repoPath = checkout.facts.repositoryPath
        task.branchName = checkout.branch
        // Deleting a worktree task offers to remove the worktree, which the
        // main checkout must never be.
        task.workspaceKind = checkout.facts.isWorktree ? .worktree : .directory
        if params.select { windows.first?.reveal(task.id) }
        var response = CLIResponse.success
        response.taskID = task.id
        return response
    }

    /// Git answers with symlinks resolved, so `/var/…` must match
    /// `/private/var/…`.
    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func openSettings(_ params: CLIRequest.OpenSettings) -> CLIResponse {
        var pane: SettingsPane?
        if let section = params.section {
            guard let named = SettingsPane(rawValue: section) else {
                return .failure("no settings section \(section)")
            }
            pane = named
        }
        guard let window = frontmostFirst.first else {
            return .failure("no Plume window is open")
        }
        if let pane { settingsDefaults.set(pane.rawValue, forKey: SettingsPane.selectionKey) }
        activateApp()
        window.openSettings()
        return .success
    }

    private func newTab(_ params: CLIRequest.NewTab) -> CLIResponse {
        let windows = frontmostFirst
        let taskID: UUID
        if let requested = params.taskID {
            taskID = requested
        } else if let tabID = params.tabID {
            guard let owner = windows.lazy.compactMap({ $0.taskIDForTab(tabID) }).first else {
                return .failure("no Plume tab \(tabID.uuidString)")
            }
            taskID = owner
        } else {
            return .failure("tab.new needs a taskID or tabID")
        }
        guard let (task, context) = windows.lazy.compactMap({ window in window.task(taskID).map { ($0, window.context) } }).first else {
            return .failure("no Plume task \(taskID.uuidString)")
        }
        if let directory = params.directory {
            guard directory.hasPrefix("/") else {
                return .failure("directory must be an absolute path: \(directory)")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure("no such directory: \(directory)")
            }
        }
        let tab = Self.addTerminalTab(
            to: task, directory: params.directory, select: params.select, in: context, directories: directories
        )
        if params.select { windows.first?.reveal(taskID) }
        var response = CLIResponse.success
        response.tabID = tab.id
        return response
    }

    /// Unless asked to select it, the new tab opens behind whatever the user
    /// has selected, since a script rarely means to steal focus.
    static func addTerminalTab(
        to task: WorkTask,
        directory: String?,
        select: Bool,
        in context: ModelContext,
        directories: TabDirectoryStore = .shared
    ) -> TaskTab {
        let previous = task.selectedTabID.flatMap { id in task.tabs.first { $0.id == id } }
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        directories.setDirectory(directory, forTab: tab)
        if !select, let previous {
            TaskStore.selectTab(previous, in: task)
        }
        return tab
    }
}
