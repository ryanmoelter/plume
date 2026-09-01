#if DEBUG
import os // Logger string interpolation
import SwiftData
import SwiftUI

/// Drives the app from environment variables so terminal behaviour can be
/// checked without UI scripting, which needs Accessibility permission this
/// environment does not have.
///
/// `PLUME_SEED_TASKS=<n>` creates n tasks and selects the first.
/// `PLUME_CYCLE_SELECTION=<seconds>` then rotates the selection on that
/// interval, so surface survival across task switches is observable from
/// outside the app by watching the child processes.
@MainActor
enum SmokeHarness {
    static func runIfRequested(context: ModelContext, selection: Binding<UUID?>) async {
        let environment = ProcessInfo.processInfo.environment
        guard let countValue = environment["PLUME_SEED_TASKS"],
              let count = Int(countValue), count > 0
        else { return }

        let existing = (try? context.fetch(FetchDescriptor<WorkTask>())) ?? []
        var tasks = existing
        while tasks.count < count {
            tasks.append(TaskStore.createTask(in: context, title: "Task \(tasks.count + 1)", siblings: tasks))
        }

        // PLUME_SEED_TABS gives the first task extra terminal tabs, so
        // several surfaces are mounted at once. Selection lands on the first
        // tab afterward, unless PLUME_SEED_AGENT_SESSION_ID is also set, in
        // which case the last-added terminal tab stays selected so the
        // agent tab's lazy auto-resume can be observed happening later, on
        // an explicit selection, rather than immediately at seed time.
        if let tabsValue = environment["PLUME_SEED_TABS"],
           let tabCount = Int(tabsValue), let first = tasks.first {
            while first.tabs.count < tabCount {
                TaskStore.addTab(to: first, kind: .terminal, in: context)
            }
            if environment["PLUME_SEED_AGENT_SESSION_ID"] == nil {
                first.orderedTabs.first.map { TaskStore.selectTab($0, in: first) }
            }
        }

        // PLUME_SEED_CWD gives the first task a working directory, so agent
        // tabs can launch without a folder picker.
        if let cwd = environment["PLUME_SEED_CWD"], let first = tasks.first {
            first.workingDirectoryPath = cwd
            first.workspaceKind = .directory
        }

        // PLUME_SEED_AGENT_SESSION_ID stores a session ID on the first task's
        // agent tab without launching anything, so lazy auto-resume can be
        // observed on first selection instead of at seed time.
        if let sessionID = environment["PLUME_SEED_AGENT_SESSION_ID"],
           let first = tasks.first,
           let agentTab = first.orderedTabs.first(where: { $0.kind == .agent }) {
            agentTab.agentSessionID = sessionID
        }

        selection.wrappedValue = tasks.first?.id
        Log.app.info("Smoke harness seeded \(tasks.count) task(s)")

        // PLUME_SEND_MESSAGE launches the agent through the same path the
        // send button uses, since UI scripting is unavailable here.
        if let message = environment["PLUME_SEND_MESSAGE"],
           let first = tasks.first,
           let agentTab = first.orderedTabs.first(where: { $0.kind == .agent }) {
            AgentLauncher.launch(message: message, task: first, tab: agentTab)
            Log.app.info("Smoke harness sent first message to agent tab")
        }

        guard let intervalValue = environment["PLUME_CYCLE_SELECTION"],
              let interval = Double(intervalValue), interval > 0
        else { return }

        var index = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            index += 1

            // Rotate the visible tab too, so hide/show is exercised alongside
            // task switching.
            if let first = tasks.first, first.tabs.count > 1 {
                let tabs = first.orderedTabs
                TaskStore.selectTab(tabs[index % tabs.count], in: first)
            }

            let task = tasks[index % tasks.count]
            selection.wrappedValue = task.id
            Log.app.info("Smoke harness selected task \(index % tasks.count + 1) of \(tasks.count)")
        }
    }
}
#endif
