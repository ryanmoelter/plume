import Foundation
import Observation

/// Where each tab currently is on disk: an agent tab's transcript `cwd`, a
/// terminal tab's OSC 7 reported directory.
///
/// The live value is in memory, like every other live-process fact, but it is
/// also written through to `TaskTab.workingDirectoryPath` so a tab that moved
/// into a worktree reopens there instead of at its task's folder.
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

    /// Both writers report through a view, which holds the model object — so
    /// the write-through takes the tab rather than looking it up.
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

    /// Where a tab is, falling back to its task's folder while it has reported
    /// nothing.
    func directory(for tab: TaskTab) -> String? {
        directories[tab.id] ?? tab.workingDirectoryPath ?? tab.task?.workingDirectoryPath
    }

    /// Where a *new* tab in this task should start: wherever the task's work
    /// has moved to, else the task's own folder.
    ///
    /// The preference order matches `TitleStore.representativeTab(of:)`, so a
    /// new terminal opens beside whatever the sidebar is describing.
    func startingDirectory(for task: WorkTask) -> String? {
        let preferred = [task.lastFocusedAgentTabID, task.selectedTabID].compactMap { $0 }
        let order = preferred + task.orderedTabs.map(\.id)
        let byID = Dictionary(task.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reported = order.lazy.compactMap { id in
            self.directories[id] ?? byID[id]?.workingDirectoryPath
        }
        return reported.first ?? task.workingDirectoryPath
    }
}
