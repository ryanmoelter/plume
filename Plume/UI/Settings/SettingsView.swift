import AppKit
import SwiftUI

/// The app's `Settings` scene (⌘,). A stub in v1: a worktree base path
/// override, read by `WorkspaceProvisioner`, and a provider field, read by
/// `AgentLauncher` via `AgentProviderRegistry`.
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var installError: String?

    private var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude")
            .appending(path: "settings.json")
    }

    private var claudeSettingsBackupURL: URL {
        claudeSettingsURL.appendingPathExtension("plume-backup")
    }

    /// Whether `statusLine` currently points at Plume's script. Read from disk
    /// rather than mirrored into a setting, so an install made by the other
    /// build — or an edit made by hand — reads correctly here.
    private var isStatuslineInstalled: Bool {
        StatuslineInstaller.isAlreadyInstalled(settingsURL: claudeSettingsURL)
    }

    private var restoreEffectDescription: String {
        guard let previous = settings.statuslineBackedUpCommand else {
            return "Restore will remove your statusLine setting."
        }
        return "Restore will put back: \(previous)"
    }

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
                if isStatuslineInstalled {
                    Text("Installed. \(restoreEffectDescription)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(StatuslineInstaller.preview(settingsURL: claudeSettingsURL))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                }

                HStack {
                    if isStatuslineInstalled {
                        Button("Restore") { restore() }
                    } else {
                        Button("Install") { install() }
                    }
                    if let installError {
                        Text(installError)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Statusline Capture")
            } footer: {
                Text("Quota and session cost exist only in the payload Claude Code sends its statusline command, nowhere on disk. Install writes to ~/.claude/settings.json outside Plume, replacing statusLine with a script that captures the payload and then runs your previous command unchanged, so your terminal statusline looks the same. That file is global, so the script also runs in terminals Plume didn't launch — there it captures nothing and just runs your own command. Restore puts your previous statusLine back.")
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

    private func install() {
        installError = nil
        do {
            let previous = try StatuslineInstaller.install(
                settingsURL: claudeSettingsURL,
                backupURL: claudeSettingsBackupURL
            )
            settings.statuslineBackedUpCommand = previous?.command
        } catch {
            installError = "Install failed: \(error.localizedDescription)"
        }
    }

    private func restore() {
        installError = nil
        do {
            try StatuslineInstaller.restore(
                settingsURL: claudeSettingsURL,
                backupURL: claudeSettingsBackupURL
            )
            settings.statuslineBackedUpCommand = nil
        } catch {
            installError = "Restore failed: \(error.localizedDescription)"
        }
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
