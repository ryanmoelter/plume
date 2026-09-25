import SwiftUI

struct AgentsSettingsPane: View {
    @State private var settings = AppSettings.shared

    private var displayedProviders: Set<AgentProviderKind>? {
        AgentCLIAvailability.shared.providers.map { AgentCLIInstallation.displayedProviders($0) }
    }

    var body: some View {
        Form {
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
            } footer: {
                Text("Existing tabs keep their agent. Codex support is in beta, tested with Codex CLI 0.153.4.")
                    .foregroundStyle(.secondary)
            }

            if let installedProviders = displayedProviders, installedProviders.count < AgentProviderKind.allCases.count {
                Section("Install agents") {
                    ForEach(AgentProviderKind.allCases.filter { !installedProviders.contains($0) }) { provider in
                        Link(destination: AgentCLIInstallation.downloadURL(for: provider)) {
                            Label {
                                Text(AgentCLIInstallation.downloadTitle(for: provider))
                            } icon: {
                                AgentProviderIcon(provider: provider)
                            }
                        }
                        .plumeID("settings-install-cli", label: provider.rawValue)
                    }
                }
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
                Text("Headless shows the agent as a chat, where you can answer its questions and permission prompts. Terminal runs the agent's own terminal interface.")
                    .foregroundStyle(.secondary)
            }

            Section {
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
                Toggle("Show Bypass Permissions / Full Access", isOn: $settings.showsBypassPermissions)
            } header: {
                Text("Default Permissions")
            } footer: {
                Text(settings.defaultProvider == .claudeCode
                    ? "Follow Claude Code uses permissions.defaultMode from ~/.claude/settings.json."
                    : "A Codex profile sets the file and network access of a new tab.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New agent tabs think at", selection: $settings.defaultEffort) {
                    ForEach(settings.defaultProvider.efforts) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
            } header: {
                Text("Default Effort")
            } footer: {
                Text("You can change the effort of a tab from its chat.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
