#if DEBUG
import SwiftUI

struct AgentInstallationDebugSection: View {
    @State private var debug = AgentInstallationDebug.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        Section {
            ForEach(AgentProviderKind.allCases) { provider in
                Picker(provider.displayName, selection: Binding(
                    get: { debug.overrides[provider] ?? .automatic },
                    set: { debug.overrides[provider] = $0 }
                )) {
                    ForEach(AgentInstallationDebug.Installation.allCases) { state in
                        Text(state.label).tag(state)
                    }
                }
                .plumeID("debug-cli-installation", label: provider.rawValue,
                    value: (debug.overrides[provider] ?? .automatic).rawValue,
                    setValue: { value in
                        if let state = AgentInstallationDebug.Installation(rawValue: value) {
                            debug.overrides[provider] = state
                        }
                    })

                HStack {
                    Text(settings.dismissedMissingProviders.contains(provider) ? "Install section dismissed" : "Install section not dismissed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset dismiss") {
                        settings.resetMissingProviderDismissal(provider)
                    }
                    .plumeID("debug-cli-reset-dismiss", label: provider.rawValue, invoke: {
                        settings.resetMissingProviderDismissal(provider)
                    })
                    .disabled(!settings.dismissedMissingProviders.contains(provider))
                }
            }
            Button("Reset installation overrides") { debug.overrides = [:] }
                .plumeID("debug-cli-reset-overrides", invoke: { debug.overrides = [:] })
        } header: {
            Text("Agent installation (Debug)")
        } footer: {
            Text("Preview the model menu, install links, and quota visibility. Overrides reset when Plume quits and do not install a CLI or change running sessions.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
