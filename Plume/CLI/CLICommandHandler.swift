import Foundation
import SwiftData

/// Answers the requests `CLIServer` receives.
@MainActor
final class CLICommandHandler {
    static let shared = CLICommandHandler()

    struct Workspace {
        var task: WorkTask
        var context: ModelContext
        /// Shows the task in the window, for `tab new --select`.
        var reveal: () -> Void
    }

    /// Finds a task by ID. `MainWindow` installs it, keeping SwiftData
    /// queries out of here; nil means no window has loaded yet.
    var workspace: (UUID) -> Workspace? = { _ in nil }

    /// The task a tab belongs to now. Installed alongside `workspace`.
    var taskIDForTab: (UUID) -> UUID? = { _ in nil }

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
        let taskID: UUID
        if let requested = params.taskID {
            taskID = requested
        } else if let tabID = params.tabID {
            guard let owner = taskIDForTab(tabID) else { return .failure("no Plume tab \(tabID.uuidString)") }
            taskID = owner
        } else {
            return .failure("tab.new needs a taskID or tabID")
        }
        guard let workspace = workspace(taskID) else {
            return .failure("no Plume task \(taskID.uuidString)")
        }
        if let directory = params.directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure("no such directory: \(directory)")
            }
        }
        let tab = Self.addTerminalTab(
            to: workspace.task, directory: params.directory, select: params.select, in: workspace.context
        )
        if params.select { workspace.reveal() }
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
        in context: ModelContext
    ) -> TaskTab {
        let previous = task.selectedTabID.flatMap { id in task.tabs.first { $0.id == id } }
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        tab.launchDirectoryPath = directory
        if !select, let previous {
            TaskStore.selectTab(previous, in: task)
        }
        return tab
    }
}
