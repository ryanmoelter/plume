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

            Section("Defaults") {
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
                    Text("Pretty").tag(AgentTransport.headless)
                    Text("Terminal (TUI)").tag(AgentTransport.terminal)
                }
                .pickerStyle(.radioGroup)

                Picker("New agent tabs think at", selection: $settings.defaultEffort) {
                    ForEach(settings.defaultProvider.efforts) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
            }

            if isInstalled(.claudeCode) {
                Section(AgentProviderKind.claudeCode.displayName) {
                    Picker("New tabs start in", selection: $settings.defaultPermissionMode) {
                        ForEach(PermissionModeDefault.offered(showsBypassPermissions: settings.showsBypassPermissions)) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("Show bypass permissions", isOn: $settings.showsBypassPermissions)
                }
            }

            if isInstalled(.codex) {
                Section("Codex") {
                    Picker("New tabs start in", selection: $settings.defaultCodexCollaborationMode) {
                        ForEach(CodexCollaborationMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("Permissions", selection: $settings.defaultCodexPermissionProfileRaw) {
                        ForEach(AgentPermissionPreset.offeredCodexProfiles(AgentPermissionPreset.codexPresets, showsFullAccess: settings.showsCodexFullAccess)) { profile in
                            Text(profile.label).tag(profile.id)
                        }
                    }
                    Toggle("Show full access", isOn: $settings.showsCodexFullAccess)
                }
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
                Link(destination: AgentCLIInstallation.downloadURL(for: provider)) {
                    Label("Install", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
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

    private func isInstalled(_ provider: AgentProviderKind) -> Bool {
        displayedProviders?.contains(provider) ?? false
    }
}
