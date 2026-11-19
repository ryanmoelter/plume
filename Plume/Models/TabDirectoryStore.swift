import Foundation
import Observation

/// Where each tab currently is on disk: an agent tab's transcript `cwd`, a
/// terminal tab's OSC 7 reported directory.
///
/// The live value is in memory, like every other live-process fact, but it is
/// also written through to `TaskTab.workingDirectoryPath` so a tab that moved
/// into a worktree reopens there instead of at its workspace's folder.
@MainActor
@Observable
final class TabDirectoryStore {
    static let shared = TabDirectoryStore()

    private(set) var directories: [UUID: String] = [:]

    init() {}

    func directory(forTab id: UUID) -> String? {
        directories[id]
    }

    func setDirectory(_ path: String?, forTab id: UUID) {
        guard let path else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, directories[id] != trimmed else { return }
        directories[id] = trimmed
    }

    /// Takes the model object, which every caller already holds, so the
    /// write-through needs no lookup.
    func setDirectory(_ path: String?, forTab tab: TaskTab) {
        setDirectory(path, forTab: tab.id)
        guard let resolved = directories[tab.id], tab.workingDirectoryPath != resolved else { return }
        tab.workingDirectoryPath = resolved
    }

    func forget(tabID: UUID) {
        directories.removeValue(forKey: tabID)
    }

    func reset() {
        directories.removeAll()
    }

    func directory(for tab: TaskTab) -> String? {
        directories[tab.id] ?? tab.workingDirectoryPath
    }

    /// `tab`'s workspace, at the folder it is in now. A tab whose live folder
    /// has left its saved one may be in another repository altogether, so it
    /// passes on only the folder, and git resolves the rest.
    func currentWorkspace(of tab: TaskTab) -> TabWorkspace {
        guard let live = directories[tab.id], live != tab.workingDirectoryPath else { return tab.workspace }
        return .directory(live)
    }

    /// The tab whose workspace stands for `task` when a new tab or task copies
    /// one: the selected tab, else the last focused agent tab, else the first
    /// tab with a folder.
    func workspaceSource(in task: WorkTask, excluding excludedTabID: UUID? = nil) -> TaskTab? {
        Self.workspaceSource(in: task, excluding: excludedTabID) { directory(for: $0) != nil }
    }

    /// `workspaceSource(in:)` from saved folders alone, for a view body that
    /// must not observe every tab's live folder.
    static func savedWorkspaceSource(in task: WorkTask) -> TaskTab? {
        workspaceSource(in: task, excluding: nil) { $0.workingDirectoryPath != nil }
    }

    private static func workspaceSource(
        in task: WorkTask,
        excluding excludedTabID: UUID?,
        hasFolder: (TaskTab) -> Bool
    ) -> TaskTab? {
        let tabs = task.orderedLiveTabs.filter { $0.id != excludedTabID }
        let preferred = [task.selectedTabID, task.lastFocusedAgentTabID].compactMap { id in
            tabs.first { $0.id == id }
        }
        return (preferred + tabs).first(where: hasFolder)
    }

    /// Where a tab's terminal starts: a directory already set for it, as by
    /// `plume tab new --cwd`, else the folder it saved before a relaunch,
    /// else where its task's other tabs are. A saved folder that has since
    /// been deleted is skipped, since a shell can't start there.
    func startingDirectory(for tab: TaskTab, in task: WorkTask) -> String? {
        directories[tab.id] ?? existingFolder(tab.workingDirectoryPath) ?? startingDirectory(for: task, excluding: tab.id)
    }

    private func existingFolder(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }

    /// Where a tab in this task with no folder of its own should start: the
    /// folder a new tab would copy.
    func startingDirectory(for task: WorkTask, excluding excludedTabID: UUID? = nil) -> String? {
        workspaceSource(in: task, excluding: excludedTabID).flatMap(directory(for:))
    }
}
