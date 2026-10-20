import Foundation
import SwiftData

@Model
final class WorkTask {
    var id: UUID = UUID()
    var title: String = ""
    /// One line the sidebar shows under the title. Empty hides it.
    var taskDescription: String = ""
    /// A `SidebarTint` raw value. Nil inherits the group's color.
    var tintRaw: String? = nil
    /// An SF Symbol name. Unlike the color, never inherited from the group.
    var iconName: String? = nil
    var orderIndex: Int = 0
    var createdAt: Date = Date()

    /// nil means the task lives in the "Ungrouped" section.
    var group: TaskGroup?

    var workspaceKindRaw: String = WorkspaceKind.unset.rawValue
    var workingDirectoryPath: String?
    var repoPath: String?
    var branchName: String?
    /// Nil launches `claude` without `--permission-mode`, leaving the CLI's
    /// own default in charge rather than asserting one.
    var permissionModeRaw: String?

    /// Snapshot so the sidebar can show badges before any agent process is live.
    var lastStatusRaw: String = TaskStatus.notStarted.rawValue
    var isArchived: Bool = false
    /// Nil for a task archived before this field existed, or one never
    /// archived at all; the archive list treats nil as oldest.
    var archivedAt: Date? = nil

    /// Reserved for PR/Linear integration payloads.
    var integrationsData: Data?

    /// The record this task was imported from, namespaced by source app
    /// (`cmux:<uuid>`), so a second import skips it. Nil for a task Plume
    /// created itself.
    ///
    /// An imported task shares its directory with the app it came from, which
    /// still believes it owns it — so anything that deletes a worktree has to
    /// account for that.
    var importedStableID: String?

    @Relationship(deleteRule: .cascade, inverse: \TaskTab.task)
    var tabs: [TaskTab] = []
    var selectedTabID: UUID?
    /// Which agent tab's title stands in for the task in the sidebar, so
    /// dipping into a terminal tab doesn't relabel the row.
    var lastFocusedAgentTabID: UUID?
    /// Each pane's selected tab, left to right, as comma-separated UUIDs.
    /// `selectedTabID` is the focused pane's and wins over its entry here.
    /// Only `TaskStore` writes it.
    var paneSelectedTabIDsRaw: String = ""
    /// The leading pane's share of the detail width.
    var splitFraction: Double = 0.5

    init(title: String, orderIndex: Int, group: TaskGroup? = nil) {
        self.id = UUID()
        self.title = title
        self.orderIndex = orderIndex
        self.createdAt = Date()
        self.group = group
    }

    var tint: SidebarTint? {
        get { tintRaw.flatMap(SidebarTint.init(rawValue:)) }
        set { tintRaw = newValue?.rawValue }
    }

    var permissionMode: PermissionMode? {
        get { permissionModeRaw.flatMap(PermissionMode.init(rawValue:)) }
        set { permissionModeRaw = newValue?.rawValue }
    }

    var workspaceKind: WorkspaceKind {
        get { WorkspaceKind(rawValue: workspaceKindRaw) ?? .unset }
        set { workspaceKindRaw = newValue.rawValue }
    }

    var lastStatus: TaskStatus {
        get { TaskStatus(migratingRawValue: lastStatusRaw) }
        set { lastStatusRaw = newValue.rawValue }
    }

    /// Every tab, pane by pane, each pane in strip order.
    var orderedTabs: [TaskTab] {
        Self.inPaneOrder(tabs)
    }

    /// `tabs` without any tab that is deleted or outside a context. Deleting
    /// a task leaves its cascade-deleted tabs listed in `tabs`, and reading a
    /// property of one can trap, so the sidebar reads this instead.
    var liveTabs: [TaskTab] {
        tabs.filter(\.isLive)
    }

    var orderedLiveTabs: [TaskTab] {
        Self.inPaneOrder(liveTabs)
    }

    private static func inPaneOrder(_ tabs: [TaskTab]) -> [TaskTab] {
        tabs.sorted { ($0.paneIndex, $0.orderIndex) < ($1.paneIndex, $1.orderIndex) }
    }

    /// `TaskStore` keeps `TaskTab.paneIndex` dense, so the highest one
    /// counts the panes.
    var paneCount: Int {
        (tabs.map(\.paneIndex).max() ?? 0) + 1
    }

    var isSplit: Bool { paneCount > 1 }

    var focusedPane: Int {
        tabs.first { $0.id == selectedTabID }?.paneIndex ?? 0
    }

    /// In strip order.
    func tabs(inPane pane: Int) -> [TaskTab] {
        tabs.filter { $0.paneIndex == pane }.sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Every pane's tabs, left to right. Each read regroups, so a view body
    /// reads it once and passes it down.
    var panes: [[TaskTab]] {
        let ordered = orderedTabs
        return (0..<paneCount).map { pane in ordered.filter { $0.paneIndex == pane } }
    }

    var paneSelectedTabIDs: [UUID?] {
        get {
            guard !paneSelectedTabIDsRaw.isEmpty else { return [] }
            return paneSelectedTabIDsRaw.split(separator: ",", omittingEmptySubsequences: false)
                .map { UUID(uuidString: String($0)) }
        }
        set { paneSelectedTabIDsRaw = newValue.map { $0?.uuidString ?? "" }.joined(separator: ",") }
    }

    /// The tab each pane shows, left to right. Unsplit, that is the focused
    /// tab alone, or nothing when none is selected.
    var paneTabIDs: [UUID] {
        paneTabIDs(in: panes)
    }

    /// `paneTabIDs` for `panes` already read from this task.
    func paneTabIDs(in panes: [[TaskTab]]) -> [UUID] {
        guard panes.count > 1 else { return selectedTabID.map { [$0] } ?? [] }
        let remembered = paneSelectedTabIDs
        return panes.enumerated().compactMap { index, tabs in
            let ids = tabs.map(\.id)
            if let selectedTabID, ids.contains(selectedTabID) { return selectedTabID }
            if remembered.indices.contains(index), let id = remembered[index], ids.contains(id) { return id }
            return ids.first
        }
    }

    /// Never had an agent session — not merely idle right now.
    /// `TaskStatus.notStarted` also covers a task that ran and lost its
    /// process to relaunch, so it can't tell "never started" from "was
    /// running, now nothing to show." An `agentSessionID` is the durable
    /// record of a session ever having run; its absence on every agent tab is
    /// what "never started" actually means.
    var hasNeverStarted: Bool {
        !liveTabs.contains { $0.kind == .agent && $0.agentSessionID != nil }
    }
}
