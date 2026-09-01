import SwiftUI

/// An agent tab with a stored session and no live process yet.
///
/// Resumes automatically the first time the tab becomes selected — not at
/// mount, since `TabContentView` keeps every tab mounted and only toggles
/// opacity. Resuming is free until a message is sent (`claude --resume` just
/// reads the transcript and waits at the prompt), so there is no need to make
/// the user confirm it; "Start Fresh" is the deliberate, confirmed action
/// (tab context menu / Tab menu) because it discards the only pointer back to
/// the conversation.
struct AutoResumingAgentTabView: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isSelected: Bool

    @State private var hasResumed = false

    var body: some View {
        Group {
            if let session = SurfaceManager.shared.existingSession(for: tab.id) {
                TerminalTabView(session: session, isVisible: isSelected)
            } else if !directoryExists {
                AgentMissingDirectoryView()
            } else {
                // Not yet selected this run, or the resume hasn't landed a
                // session yet; `TerminalTabView` takes over as soon as it does.
                Color.clear
            }
        }
        .onChange(of: isSelected, initial: true) { _, selected in
            guard selected else { return }
            resumeIfNeeded()
        }
    }

    private var directoryExists: Bool {
        guard let path = task.workingDirectoryPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func resumeIfNeeded() {
        guard !hasResumed else { return }
        guard AgentAutoResume.shouldResume(
            agentSessionID: tab.agentSessionID,
            workingDirectoryPath: task.workingDirectoryPath,
            hasExistingSurfaceSession: SurfaceManager.shared.existingSession(for: tab.id) != nil,
            directoryExists: { FileManager.default.fileExists(atPath: $0) }
        ) else { return }

        hasResumed = true
        AgentLauncher.launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
    }
}
