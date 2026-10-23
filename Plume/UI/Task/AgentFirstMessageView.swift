import SwiftUI

/// An agent tab before its first message: no `claude` process exists yet, so
/// the tab shows a native input. Submitting launches the agent.
struct AgentFirstMessageView: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    var isVisible = true
    var isFocused = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var message = ""
    @State private var resumeSheetShown = false
    @FocusState private var inputFocused: Bool

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && directoryExists
    }

    private var directoryExists: Bool {
        guard let path = task.workingDirectoryPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Start a conversation")
                .font(.headline)

            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    WorkspacePickerView(task: task)
                    Spacer()
                    Group {
                        Button("Resume…") { resumeSheetShown = true }
                            .buttonStyle(.link)
                            .disabled(!directoryExists)
                            .help("Continue a past conversation in this folder")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    TextField("Message…", text: $message, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onSubmit(send)
                        .plumeID(AccessibilityID.agentFirstMessageField, value: message, setValue: { message = $0 })

                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .plumeID(AccessibilityID.agentFirstMessageSendButton, invoke: send)
                        .disabled(!canSend)
                }
                ComposerControlsRow(task: task, tab: tab, headlessSession: nil)
            }
            .frame(maxWidth: 560)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
        .claimsPaneFocus(isVisible: isVisible, isFocused: isFocused) {
            inputFocused = true
        }
        .sheet(isPresented: $resumeSheetShown) {
            if let path = task.workingDirectoryPath {
                ResumeSessionSheet(
                    workingDirectory: path,
                    repoPath: task.repoPath,
                    provider: tab.provider,
                    onSelect: resume
                )
            }
        }
    }

    private func send() {
        guard canSend else { return }
        AgentLauncher.launch(message: message, task: task, tab: tab)
        message = ""
    }

    /// Storing the ID is the whole resume: `TabContentView` swaps this view
    /// for `AutoResumingAgentTabView`, which launches `claude --resume`.
    private func resume(_ session: StoredSession) {
        if tab.agentSessionID != session.sessionID {
            TitleStore.shared.beginNewConversation(forTab: tab.id)
        }
        tab.agentSessionID = session.sessionID
        tab.sessionJSONLPath = tab.provider == .claudeCode ? session.transcriptPath : nil
    }
}
