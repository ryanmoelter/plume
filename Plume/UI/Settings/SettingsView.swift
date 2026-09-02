import AppKit
import SwiftUI

/// The app's `Settings` scene (⌘,). A stub in v1: a worktree base path
/// override, read by `WorkspaceProvisioner`, and a provider field, read by
/// `AgentLauncher` via `AgentProviderRegistry`.
struct SettingsView: View {
    @State private var settings = AppSettings.shared

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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
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
