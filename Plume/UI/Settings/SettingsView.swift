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
