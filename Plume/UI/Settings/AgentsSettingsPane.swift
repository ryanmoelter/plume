import SwiftUI

struct AgentsSettingsPane: View {
    @State private var settings = AppSettings.shared

    private var displayedProviders: Set<AgentProviderKind>? {
        AgentCLIAvailability.shared.providers.map { AgentCLIInstallation.displayedProviders($0) }
    }

    var body: some View {
        Form {
            Section("Agent accounts") {
                ForEach(AgentProviderKind.allCases) { provider in
                    agentAccountRow(for: provider)
                }
            }

            Section {
                Picker("New agent tabs run", selection: $settings.defaultProvider) {
                    ForEach(AgentProviderKind.allCases) { provider in
                        Label {
                            Text(provider == .codex ? "Codex (Beta)" : provider.displayName)
                        } icon: {
                            AgentProviderIcon(provider: provider)
                        }
                        .tag(provider)
                    }
                }

                Picker("New agent tabs use", selection: $settings.defaultAgentTransport) {
                    Text("Headless").tag(AgentTransport.headless)
                    Text("Terminal (TUI)").tag(AgentTransport.terminal)
                }
                .pickerStyle(.radioGroup)

                if settings.defaultProvider == .claudeCode {
                    Picker("New agent tabs start in", selection: $settings.defaultPermissionMode) {
                        ForEach(PermissionModeDefault.offered(showsBypassPermissions: settings.showsBypassPermissions)) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                } else {
                    Picker("New agent tabs start in", selection: $settings.defaultCodexPermissionProfileRaw) {
                        ForEach(AgentPermissionPreset.offeredCodexProfiles(AgentPermissionPreset.codexPresets, showsFullAccess: settings.showsBypassPermissions)) { profile in
                            Text(profile.label).tag(profile.id)
                        }
                    }
                }
                Toggle("Show bypass permissions / full access", isOn: $settings.showsBypassPermissions)

                Picker("New agent tabs think at", selection: $settings.defaultEffort) {
                    ForEach(settings.defaultProvider.efforts) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text(defaultsFooterText)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func agentAccountRow(for provider: AgentProviderKind) -> some View {
        LabeledContent {
            switch displayedProviders {
            case nil:
                Text("Checking…")
                    .foregroundStyle(.secondary)
            case .some(let installed) where installed.contains(provider):
                Text("Installed")
                    .foregroundStyle(.secondary)
            case .some:
                Link("Install…", destination: AgentCLIInstallation.downloadURL(for: provider))
                    .plumeID("settings-install-cli", label: provider.rawValue)
            }
        } label: {
            Label {
                Text(provider == .codex ? "Codex (Beta)" : provider.displayName)
            } icon: {
                AgentProviderIcon(provider: provider)
            }
        }
    }

    private var defaultsFooterText: String {
        let permissionsFootnote = settings.defaultProvider == .claudeCode
            ? "Follow Claude Code uses permissions.defaultMode from ~/.claude/settings.json."
            : "A Codex profile sets the file and network access of a new tab."
        return [
            "Existing tabs keep their agent. Codex support is in beta, tested with Codex CLI 0.153.4.",
            "Headless shows the agent as a chat, where you can answer its questions and permission prompts. Terminal runs the agent's own terminal interface.",
            permissionsFootnote,
            "You can change the effort of a tab from its chat.",
        ].joined(separator: " ")
    }
}
