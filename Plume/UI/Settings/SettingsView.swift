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
            } header: {
                Text("Chat Text Size")
            } footer: {
                Text("Sets the prose size in the chat view — messages, tool calls, and thinking blocks scale together.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Capture statusline for quota and cost", isOn: $settings.statuslineCaptureEnabled)

                Text(StatuslineInstaller.preview(settingsURL: claudeSettingsURL))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))

                HStack {
                    Button("Install") { install() }
                    Button("Restore") { restore() }
                        .disabled(settings.statuslineBackedUpCommand == nil && !StatuslineInstaller.isAlreadyInstalled(settingsURL: claudeSettingsURL))
                    if let installError {
                        Text(installError)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Statusline Capture")
            } footer: {
                Text("Quota and session cost exist only in the payload Claude Code sends its statusline command, nowhere on disk. Install writes to ~/.claude/settings.json outside Plume, replacing statusLine with a script that captures the payload and then runs your previous command unchanged, so your terminal statusline looks the same. Restore puts your previous statusLine back.")
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
            settings.statuslineCaptureEnabled = true
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
            settings.statuslineCaptureEnabled = false
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
