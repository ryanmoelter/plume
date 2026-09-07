import Foundation
import Observation

/// Where each tab currently is on disk: an agent tab's transcript `cwd`, a
/// terminal tab's OSC 7 reported directory.
///
/// In memory, like every other live-process fact. Nothing persists it — a
/// relaunch starts from the task's own folder until a tab reports again.
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

    func forget(tabID: UUID) {
        directories.removeValue(forKey: tabID)
    }

    func reset() {
        directories.removeAll()
    }

    /// Where a tab is, falling back to its task's folder while it has reported
    /// nothing.
    func directory(for tab: TaskTab) -> String? {
        directories[tab.id] ?? tab.task?.workingDirectoryPath
    }

    /// Where a *new* tab in this task should start: wherever the task's work
    /// has moved to, else the task's own folder.
    ///
    /// The preference order matches `TitleStore.representativeTab(of:)`, so a
    /// new terminal opens beside whatever the sidebar is describing.
    func startingDirectory(for task: WorkTask) -> String? {
        let preferred = [task.lastFocusedAgentTabID, task.selectedTabID].compactMap { $0 }
        let order = preferred + task.orderedTabs.map(\.id)
        return order.lazy.compactMap { self.directories[$0] }.first ?? task.workingDirectoryPath
    }
}
