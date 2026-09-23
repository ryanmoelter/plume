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
        // Seed into newly created tasks only. Reusing the user's tasks lets
        // provider/session flags corrupt conversations from earlier runs.
        var tasks: [WorkTask] = []
        while tasks.count < count {
            tasks.append(TaskStore.createTask(in: context, title: "Task \(tasks.count + 1)", siblings: existing + tasks))
        }

        // PLUME_SEED_TABS gives every task extra terminal tabs, so several
        // surfaces are mounted at once and switching tasks exercises live
        // ones. Seeding only the first task would switch between empty tab
        // trees and prove nothing about surface survival. Selection lands on
        // the first tab afterward, unless PLUME_SEED_AGENT_SESSION_ID is also
        // set, in which case the last-added terminal tab stays selected so the
        // agent tab's lazy auto-resume can be observed happening later, on
        // an explicit selection, rather than immediately at seed time.
        if let tabsValue = environment["PLUME_SEED_TABS"],
           let tabCount = Int(tabsValue) {
            for task in tasks {
                while task.tabs.count < tabCount {
                    TaskStore.addTab(to: task, kind: .terminal, in: context)
                }
                if environment["PLUME_SEED_AGENT_SESSION_ID"] == nil {
                    task.orderedTabs.first.map { TaskStore.selectTab($0, in: task) }
                }
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

        // PLUME_SEED_TRANSCRIPT_PATH points agent tabs at existing
        // transcripts, so full chats render with no `claude` process. A
        // comma-separated list gives each task its own, in order, the last
        // one repeating. The watch starts here because the launch-time
        // restore ran before the tabs were seeded.
        if let paths = environment["PLUME_SEED_TRANSCRIPT_PATH"] {
            let expanded = paths.split(separator: ",").map { NSString(string: String($0)).expandingTildeInPath }
            for (index, task) in tasks.enumerated() {
                let path = expanded[min(index, expanded.count - 1)]
                task.title = "Task \(index + 1): \((path as NSString).lastPathComponent)"
                for agentTab in task.orderedTabs where agentTab.kind == .agent {
                    agentTab.transport = .headless
                    agentTab.sessionJSONLPath = path
                    TranscriptStore.shared.watch(tabID: agentTab.id, transcriptPath: path)
                }
            }
        }

        // PLUME_SEED_PROVIDER puts newly seeded agent tabs on one CLI, so a seeded
        // run can exercise Codex instead of Claude Code.
        if let raw = environment["PLUME_SEED_PROVIDER"],
           let provider = AgentProviderKind(rawValue: raw) {
            for task in tasks {
                for agentTab in task.orderedTabs where agentTab.kind == .agent {
                    agentTab.provider = provider
                    if let model = environment["PLUME_SEED_MODEL"] {
                        agentTab.model = AgentModel.recognizing(model, provider: provider)
                        agentTab.isModelUserChosen = true
                    }
                    if let mode = environment["PLUME_SEED_CODEX_MODE"].flatMap(CodexCollaborationMode.init(rawValue:)) {
                        agentTab.codexCollaborationMode = mode
                    }
                }
            }
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

        // PLUME_SEND_MESSAGE_2 sends a second turn after a delay, so multi-turn
        // continuity over one process can be observed.
        if let second = environment["PLUME_SEND_MESSAGE_2"],
           let first = tasks.first,
           let agentTab = first.orderedTabs.first(where: { $0.kind == .agent }) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(environment["PLUME_SEND_MESSAGE_2_DELAY"] ?? "") ?? 25))
                AgentSessionManager.shared.session(for: agentTab.id, taskID: first.id).submit(text: second)
                Log.app.info("Smoke harness sent second message")
            }
        }

        // PLUME_AUTO_ANSWER exercises the answer-a-running-question path,
        // which UI scripting cannot reach (no Accessibility permission). It
        // polls the first task's agent session for a pending permission and
        // resolves the first one it sees: an AskUserQuestion gets its first
        // option on every question, ExitPlanMode gets approved, anything else
        // gets allowed as-is. Polling (rather than one delayed shot) copes
        // with not knowing in advance when the agent will actually ask.
        if environment["PLUME_AUTO_ANSWER"] != nil,
           let first = tasks.first,
           let agentTab = first.orderedTabs.first(where: { $0.kind == .agent }) {
            Task { @MainActor in
                let session = AgentSessionManager.shared.session(for: agentTab.id, taskID: first.id)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let permission = session.pendingPermissions.first else { continue }
                    autoAnswer(permission, in: session)
                    Log.app.info("Smoke harness auto-answered a pending permission")
                }
            }
        }

        // PLUME_FAKE_STREAM=<seconds> appends a chunk of markdown to the first
        // agent tab's live text on that interval, restarting the message every
        // 400 chunks, so the streaming overlay and its follow-bottom scroll
        // run against a transcript rendered from disk with no process.
        if let tickValue = environment["PLUME_FAKE_STREAM"],
           let tick = Double(tickValue), tick > 0,
           let first = tasks.first,
           let agentTab = first.orderedTabs.first(where: { $0.kind == .agent }),
           let session = AgentSessionManager.shared.session(for: agentTab.id, taskID: first.id) as? HeadlessSession {
            Task { @MainActor in
                let chunks = ["Streaming ", "some **bold** ", "text, ", "with `code` ", "and a\n\n", "new paragraph. ", "- a list item\n", "- another\n\n"]
                var index = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(tick))
                    session.debugStream(text: chunks[index % chunks.count], restart: index % 400 == 0)
                    index += 1
                    if index % 100 == 0 { Log.app.info("Smoke harness streamed \(index) chunks") }
                }
            }
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

    /// Picks the first option of every question, approves a plan, or allows
    /// anything else as-is — whatever answers the specific pending request so
    /// the turn can proceed, since the point is exercising the resume path,
    /// not the choice made.
    private static func autoAnswer(_ permission: PendingPermission, in session: any AgentSession) {
        switch permission.interactive {
        case .questions(let questions):
            var answers: [String: String] = [:]
            for question in questions {
                if let firstOption = question.options.first {
                    answers[question.question] = firstOption.label
                }
            }
            session.answer(permission, answers: answers)
        case .plan:
            session.approvePlan(permission)
        case nil:
            session.resolve(permission, with: .allow(updatedInput: permission.input))
        }
    }
}
#endif
