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

    func handle(_ request: CLIRequest) -> CLIResponse {
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
        }
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
