import Foundation
import SwiftData

/// Turns validated candidates into tasks, groups and tabs.
///
/// Knows nothing about the app a candidate came from — adding a second source
/// means writing a parser that produces `ImportCandidate`, not touching this.
@MainActor
enum Importer {
    /// `stableID`s the store already holds. Fetched rather than read from a
    /// `@Query` so archived tasks count: archiving an imported task must not
    /// make the next import bring it back.
    static func alreadyImported(in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<WorkTask>(
            predicate: #Predicate { $0.importedStableID != nil }
        )
        let tasks = (try? context.fetch(descriptor)) ?? []
        return Set(tasks.compactMap(\.importedStableID))
    }

    /// Whether the task this candidate would replace still has a live agent or
    /// terminal, which replacing it would stop mid-turn.
    static func hasLiveSession(stableID: String, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<WorkTask>(
            predicate: #Predicate { $0.importedStableID == stableID }
        )
        let tasks = (try? context.fetch(descriptor)) ?? []
        return tasks.contains { task in
            task.tabs.contains { tab in
                SurfaceManager.shared.existingSession(for: tab.id) != nil
                    || HeadlessSessionManager.shared.existingSession(for: tab.id) != nil
            }
        }
    }

    /// Every session id a tab already holds. `--resume` is not a fork, so a
    /// candidate may not claim one of these.
    static func heldSessionIDs(in context: ModelContext) -> Set<String> {
        let tabs = (try? context.fetch(FetchDescriptor<TaskTab>())) ?? []
        return Set(tabs.compactMap(\.agentSessionID).filter { !$0.isEmpty })
    }

    /// Marks what the store already knows about, so the sheet can disable
    /// those rows before anyone presses Import.
    static func marking(
        _ candidates: [ImportCandidate],
        alreadyImported: Set<String>
    ) -> [ImportCandidate] {
        candidates.map { candidate in
            var marked = candidate
            marked.isAlreadyImported = alreadyImported.contains(candidate.stableID)
            return marked
        }
    }

    @discardableResult
    static func importing(
        _ candidates: [ImportCandidate],
        into target: ImportTarget,
        in context: ModelContext
    ) -> [WorkTask] {
        var tasks = (try? context.fetch(FetchDescriptor<WorkTask>())) ?? []
        var groups = (try? context.fetch(FetchDescriptor<TaskGroup>())) ?? []
        // Re-read rather than trust the sheet: the store can change while it is
        // open, and a session claimed twice is the one mistake that corrupts a
        // conversation rather than just cluttering the sidebar.
        var imported = alreadyImported(in: context)
        var heldSessions = heldSessionIDs(in: context)

        var created: [WorkTask] = []
        for candidate in candidates {
            guard candidate.isImportable else { continue }

            // A replacement keeps the sidebar slot the old task held, so a
            // re-import does not shuffle the sidebar.
            let replaced = imported.contains(candidate.stableID)
                ? tasks.first { $0.importedStableID == candidate.stableID }
                : nil
            let inheritedIndex = replaced?.orderIndex
            let inheritedGroup = replaced?.group
            if let replaced {
                for tab in replaced.tabs {
                    heldSessions.subtract([tab.agentSessionID].compactMap { $0 })
                }
                TaskStore.delete(replaced, in: context)
                tasks.removeAll { $0.id == replaced.id }
                imported.remove(candidate.stableID)
            }

            let group = inheritedGroup
                ?? resolveGroup(for: candidate, target: target, groups: &groups, in: context)
            let siblings = tasks.filter { $0.group?.id == group?.id }
            let task = WorkTask(
                title: candidate.title,
                orderIndex: inheritedIndex ?? (siblings.map(\.orderIndex).max() ?? -1) + 1,
                group: group
            )
            task.workingDirectoryPath = candidate.workingDirectoryPath
            task.repoPath = candidate.workspace.repoPath
            task.branchName = candidate.workspace.branchName
            task.workspaceKind = candidate.workspace.kind
            task.importedStableID = candidate.stableID
            context.insert(task)

            for (index, plan) in candidate.tabs.enumerated() {
                let tab = makeTab(plan, index: index, in: task, heldSessions: &heldSessions)
                context.insert(tab)
                task.tabs.append(tab)
            }
            selectOpeningTab(of: task)

            imported.insert(candidate.stableID)
            tasks.append(task)
            created.append(task)
        }
        return created
    }

    private static func makeTab(
        _ plan: ImportTabPlan,
        index: Int,
        in task: WorkTask,
        heldSessions: inout Set<String>
    ) -> TaskTab {
        // A session another tab already holds makes this a terminal tab: the
        // directory and the pane are still worth having, the conversation
        // cannot be held twice.
        let sessionID = plan.agentSessionID.flatMap { heldSessions.contains($0) ? nil : $0 }
        let kind: TabKind = plan.kind == .agent && sessionID != nil ? .agent : .terminal

        let tab = TaskTab(kind: kind, orderIndex: index, task: task)
        tab.title = plan.title
        tab.workingDirectoryPath = plan.workingDirectoryPath

        if kind == .agent, let sessionID {
            // Pinned rather than read from settings: headless is the only
            // transport that reopens the conversation as rendered chat, which
            // is the reason to import it at all.
            tab.transport = .headless
            tab.agentSessionID = sessionID
            tab.sessionJSONLPath = plan.sessionJSONLPath
            tab.permissionMode = plan.permissionMode
            heldSessions.insert(sessionID)
        }
        return tab
    }

    private static func selectOpeningTab(of task: WorkTask) {
        guard let opening = task.orderedTabs.first(where: { $0.kind == .agent })
            ?? task.orderedTabs.first
        else { return }
        TaskStore.selectTab(opening, in: task)
    }

    private static func resolveGroup(
        for candidate: ImportCandidate,
        target: ImportTarget,
        groups: inout [TaskGroup],
        in context: ModelContext
    ) -> TaskGroup? {
        switch target {
        case .ungrouped:
            return nil
        case .existing(let id):
            return groups.first { $0.id == id }
        case .mirrorSourceGroups:
            guard let name = candidate.groupName else { return nil }
            if let match = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return match
            }
            let group = TaskStore.createGroup(in: context, name: name, existing: groups)
            groups.append(group)
            return group
        }
    }
}

extension Importer {
    /// The watches a live agent tab needs, which creating the model does not
    /// start. Without these an imported chat stays empty until the next launch.
    static func startWatches(for tasks: [WorkTask]) {
        for task in tasks {
            for tab in task.tabs where tab.kind == .agent {
                StatusEngine.shared.restore(tabID: tab.id, taskID: task.id)
                guard let path = tab.sessionJSONLPath, !path.isEmpty else { continue }
                AgentTitleMonitor.shared.watch(tabID: tab.id, transcriptPath: path)
                TranscriptStore.shared.watch(tabID: tab.id, transcriptPath: path)
            }
        }
    }
}
