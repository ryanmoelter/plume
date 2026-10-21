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
                            Text(label(for: mode)).tag(mode)
                        }
                    }
                    Picker("New tabs use", selection: $settings.defaultClaudeModel) {
                        ForEach(ClaudeModelDefault.offered(including: settings.defaultClaudeModel)) { option in
                            Text(label(for: option)).tag(option)
                        }
                    }
                    Toggle("Show bypass permissions", isOn: $settings.showsBypassPermissions)
                    Picker("Deliver queued messages", selection: $settings.queuedMessageDelivery) {
                        Text("At the end of the turn").tag(QueuedMessageDelivery.endOfTurn)
                        Text("After the current tool call (sooner)").tag(QueuedMessageDelivery.afterToolCall)
                    }
                    .plumeID(
                        AccessibilityID.queuedMessageDeliveryPicker,
                        value: settings.queuedMessageDelivery.rawValue,
                        setValue: { raw in
                            guard let delivery = QueuedMessageDelivery(rawValue: raw) else { return }
                            settings.queuedMessageDelivery = delivery
                        }
                    )
                    extraArgumentsRow
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
                    HStack(spacing: 4) {
                        Text("Install")
                        Image(systemName: "arrow.up.right.square")
                    }
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

    private var extraArgumentsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "Additional arguments for claude",
                text: $settings.claudeExtraArgumentsText,
                prompt: Text("--model opus --add-dir ~/shared")
            )
            .textFieldStyle(.roundedBorder)
            .plumeID(
                AccessibilityID.settingsClaudeExtraArgumentsField,
                value: settings.claudeExtraArgumentsText,
                setValue: { settings.claudeExtraArgumentsText = $0 }
            )
            Group {
                if let warning = extraArgumentsWarning(settings.claudeExtraArguments) {
                    Text(warning).foregroundStyle(.orange)
                }
                Text("Applies to sessions started from now on. Quoted like a shell, without variable expansion. Plume's own flags, such as --resume and --permission-mode, are ignored, and a model picked in Plume overrides --model.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func extraArgumentsWarning(_ arguments: ClaudeExtraArguments) -> String? {
        switch arguments.parseError {
        case .unterminatedQuote:
            return "Unmatched quote, so none of these are passed."
        case .trailingBackslash:
            return "Trailing backslash, so none of these are passed."
        case nil:
            guard !arguments.ignored.isEmpty else { return nil }
            return "Ignored: \(arguments.ignored.joined(separator: " "))"
        }
    }

    /// Names the CLI's own default beside the follow option, so the user can
    /// see what following it means.
    private func label(for option: ClaudeModelDefault) -> String {
        switch option {
        case .followClaudeCode:
            return ClaudeCodeSettingsResolver.resolvedDefaultModel()
                .map { "Follow Claude Code (\($0.label))" } ?? "Follow Claude Code"
        case .model(let model):
            return model.label
        }
    }

    private func label(for mode: PermissionModeDefault) -> String {
        guard mode == .followClaudeCode,
              let resolved = ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode()
        else { return mode.label }
        return "Follow Claude Code (\(resolved.label))"
    }

    private func isInstalled(_ provider: AgentProviderKind) -> Bool {
        displayedProviders?.contains(provider) ?? false
    }
}
