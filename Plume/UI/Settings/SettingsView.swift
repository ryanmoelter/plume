import AppKit
import SwiftUI

/// The app's `Settings` scene (⌘,). A stub in v1: a worktree base path
/// override, read by `WorkspaceProvisioner`, and a provider field, read by
/// `AgentLauncher` via `AgentProviderRegistry`.
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var newIgnoredCheckName = ""
    @State private var helperState = CommandLineHelper.state()
    @State private var helperError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Default (inside each repo)", text: worktreeBasePathBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseBasePath)
                    if settings.worktreeBasePath != nil {
                        Button("Reset") { settings.worktreeBasePath = nil }
                    }
                }
            } header: {
                Text("Worktree Base Path")
            } footer: {
                Text("New worktrees are created here instead of inside the repository's .plume/worktrees folder.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Provider", selection: $settings.providerID) {
                    Text("Claude Code").tag(ClaudeCodeProviderID)
                }
            } footer: {
                Text("Claude Code is the only provider available in v1.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New agent tabs use", selection: $settings.defaultAgentTransport) {
                    Text("Headless").tag(AgentTransport.headless)
                    Text("Terminal (TUI)").tag(AgentTransport.terminal)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Agent Transport")
            } footer: {
                Text("Headless drives claude directly and can answer permission prompts and questions from the chat. Terminal keeps the classic PTY-backed session as a fallback.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New agent tabs start in", selection: $settings.defaultPermissionMode) {
                    ForEach(PermissionModeDefault.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Default Permission Mode")
            } footer: {
                Text("Follow Claude Code reads permissions.defaultMode from ~/.claude/settings.json. A task's own permission mode, set from its chat, always overrides this.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New agent tabs think at", selection: $settings.defaultEffort) {
                    ForEach(AgentEffort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
            } header: {
                Text("Default Effort")
            } footer: {
                Text("A tab's own effort, set from its chat, overrides this. Claude Code never reports effort back, so this is also what the composer shows until the tab sets one.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Slider(
                        value: $settings.chatFontSize,
                        in: AppSettings.chatFontSizeRange,
                        step: 1
                    )
                    Text("\(Int(settings.chatFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Picker("Send message with", selection: $settings.composerSendKey) {
                    Text("⌘Return").tag(ComposerSendKey.commandReturn)
                    Text("Return").tag(ComposerSendKey.returnKey)
                }
            } header: {
                Text("Chat")
            } footer: {
                Text(
                    "Text size sets the prose size in the chat view — messages, tool calls, " +
                    "and thinking blocks scale together. The other key inserts a newline " +
                    "instead of sending, so a half-typed multi-line message stays editable."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use the new chat layout", isOn: Binding(
                    get: { settings.chatListEngine == .custom },
                    set: { settings.chatListEngine = $0 ? .custom : .lazyStack }
                ))
            } header: {
                Text("Chat Layout")
            } footer: {
                Text(
                    "The new layout is Plume's own scrolling list: it pins a sent " +
                    "prompt to the top of the view with room below for the reply, and " +
                    "animates the conversation itself rather than each message. Off, the " +
                    "list is the SwiftUI one it replaces. Takes effect on the next chat opened."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Animate chat message motion", isOn: $settings.animateChatMotion)
                Toggle("Reveal streamed text a character at a time", isOn: $settings.animateCharacterReveal)
            } header: {
                Text("Chat Animation")
            } footer: {
                Text(
                    "Message motion eases a message that grows or collapses into its new size, " +
                    "grows a newly arrived one into place, and slides the conversation when the " +
                    "composer changes height. The reveal draws streamed text at a readable pace " +
                    "instead of a paragraph at a time, speeding up while the agent is writing " +
                    "faster than it reads."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when an agent finishes its turn", isOn: $settings.notifiesOnTurnEnd)
            } header: {
                Text("Notifications")
            } footer: {
                Text(
                    "An agent that needs an answer — a plan to approve, a question, " +
                    "a tool waiting on permission — always notifies, and says which. " +
                    "A finished turn is quieter and far more frequent, so it is off " +
                    "by default."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(helperStatusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(helperButtonTitle, action: toggleHelperInstall)
                }
                if let helperError {
                    Text(helperError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Command Line")
            } footer: {
                Text(
                    "Installs plume-notify into ~/.local/bin, as a link into the app bundle. " +
                    "Run `plume-notify \"Build finished\" \"12 tests passed\"` from any terminal " +
                    "or agent tab and the notification routes back to that tab."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep the Mac awake", selection: $settings.keepAwakeMode) {
                    ForEach(KeepAwakeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Keep awake on battery", isOn: $settings.keepsAwakeOnBattery)
                if settings.keepsAwakeOnBattery {
                    Stepper(
                        batteryCutoffLabel,
                        value: $settings.keepAwakeBatteryCutoffPercent,
                        in: 0...100,
                        step: 5
                    )
                }
            } header: {
                Text("Keep Awake")
            } footer: {
                Text(
                    "Auto holds the Mac awake while an agent is working, while a " +
                    "session is under remote control, and while a remotely " +
                    "controlled agent waits for an answer. The system may ignore " +
                    "the request on battery or under thermal load. The hold " +
                    "releases once the battery drops to or below the cutoff, " +
                    "unless it's charging. Closing the lid sleeps the Mac unless " +
                    "it is in clamshell mode, and macOS gives apps no way to " +
                    "override that."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Confirm before quitting while an agent is working", isOn: $settings.confirmQuitWhileWorking)
                Toggle("Also confirm on logout, restart, or shutdown", isOn: $settings.confirmSystemInitiatedQuit)
            } header: {
                Text("Quit Confirmation")
            } footer: {
                Text(
                    "Quitting always ends running agent processes immediately. " +
                    "Confirming during a logout, restart, or shutdown blocks that " +
                    "shutdown until someone dismisses the prompt, so leave it off " +
                    "unless you want that."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show GitHub PR status in the sidebar", isOn: $settings.showsPullRequestStatus)

                ForEach(settings.ignoredPendingChecks, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            settings.ignoredPendingChecks.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Check name", text: $newIgnoredCheckName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIgnoredCheck)
                    Button("Add", action: addIgnoredCheck)
                        .disabled(newIgnoredCheckName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text(
                    "Names a check whose PENDING state Plume ignores while folding a PR's CI " +
                    "result — a real pass or fail from it still counts, only a check stuck " +
                    "pending forever stops masking the rest. Matching is an exact, " +
                    "case-sensitive name; a mismatch silently won't apply. The repository's " +
                    "own ryanmoelter-cli-tools.ignoredPendingChecks git config adds to this " +
                    "list rather than replacing it."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .onAppear { helperState = CommandLineHelper.state() }
    }

    private var batteryCutoffLabel: String {
        settings.keepAwakeBatteryCutoffPercent == 0
            ? "No battery cutoff"
            : "Stop below \(settings.keepAwakeBatteryCutoffPercent)%"
    }

    private var helperStatusText: String {
        switch helperState {
        case .installed: "Installed at \(CommandLineHelper.installedURL.path)"
        case .notInstalled: "Not installed"
        case .occupiedByOther: "Another file owns that name"
        case .brokenLink: "Installed, but pointing at a bundle that is gone"
        }
    }

    private var helperButtonTitle: String {
        if case .installed = helperState { "Remove" } else { "Install" }
    }

    private func toggleHelperInstall() {
        helperError = nil
        do {
            if case .installed = helperState {
                try CommandLineHelper.uninstall()
            } else {
                try CommandLineHelper.install()
            }
        } catch {
            helperError = error.localizedDescription
        }
        helperState = CommandLineHelper.state()
    }

    private func addIgnoredCheck() {
        let trimmed = newIgnoredCheckName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.ignoredPendingChecks.append(trimmed)
        newIgnoredCheckName = ""
    }

    private var worktreeBasePathBinding: Binding<String> {
        Binding(
            get: { settings.worktreeBasePath ?? "" },
            set: { settings.worktreeBasePath = $0.isEmpty ? nil : $0 }
        )
    }

    private func chooseBasePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.worktreeBasePath = url.path
    }
}
