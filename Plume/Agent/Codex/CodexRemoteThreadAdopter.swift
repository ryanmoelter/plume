import Foundation
import os
import SwiftData

/// Connects threads opened by a remote client to the persisted Plume identity.
/// Directory names are used only when creating a brand-new task.
@MainActor
enum CodexRemoteThreadAdopter {
    static func resolve(thread: JSONValue, in context: ModelContext) throws -> TaskTab? {
        guard CodexTerminalMonitor.isConversationRoot(thread),
              let id = thread["id"]?.stringValue, !id.isEmpty else { return nil }
        let tabs = try context.fetch(FetchDescriptor<TaskTab>())
        if let existing = tabs.first(where: { $0.provider == .codex && $0.agentSessionID == id }) {
            // A separate terminal server remains its own owner. Never silently
            // replace it or create a second persisted identity for that thread.
            guard existing.transport == .headless, let task = existing.task else { return nil }
            task.isArchived = false
            task.archivedAt = nil
            return existing
        }
        let tasks = try context.fetch(FetchDescriptor<WorkTask>())
        let task = WorkTask(title: "", orderIndex: (tasks.filter { $0.group == nil && !$0.isArchived }.map(\.orderIndex).max() ?? -1) + 1)
        if let cwd = thread["cwd"]?.stringValue, !cwd.isEmpty {
            task.workingDirectoryPath = cwd
            task.workspaceKind = .directory
        }
        context.insert(task)
        let tab = TaskStore.addTab(to: task, kind: .agent, provider: .codex, in: context)
        tab.transport = .headless
        tab.agentSessionID = id
        tab.title = thread["name"]?.stringValue
        return tab
    }

    static func adopt(thread: JSONValue, in context: ModelContext) async -> Bool {
        do {
            guard let tab = try resolve(thread: thread, in: context), let task = tab.task,
                  let threadID = tab.agentSessionID else { return false }
            let manager = AgentSessionManager.shared
            guard !manager.isCodexThreadOwnedElsewhere(threadID, by: tab.id) else { return false }
            if let existing = manager.existingSession(for: tab.id), existing.hasExited {
                manager.closeSession(for: tab.id)
            }
            guard manager.claimCodexThread(threadID, for: tab.id),
                  let session = manager.session(for: tab.id, taskID: task.id, provider: .codex) as? CodexSession else { return false }
            try context.save()
            session.start(workingDirectory: task.workingDirectoryPath,
                          resumeThreadID: threadID, model: nil,
                          preserveRemoteConfiguration: true, environment: [:])
            // start marks the handshake synchronously. Requests replayed by
            // the host now enter the session's deferred inbound queue and are
            // drained only once its exact thread identity has been adopted.
            return !session.hasExited
        } catch {
            Log.agent.error("Could not restore remote Codex tab: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
