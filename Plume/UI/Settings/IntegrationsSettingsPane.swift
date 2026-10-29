import SwiftUI

struct IntegrationsSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var ghInstalled: Bool?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        if ghInstalled == false {
                            Link(destination: URL(string: "https://cli.github.com")!) {
                                HStack(spacing: 4) {
                                    Text("Install")
                                    Image(systemName: "arrow.up.right.square")
                                }
                            }
                            .buttonStyle(.bordered)
                            .plumeID("settings-install-cli", label: "gh")
                        }
                        Toggle("Show PR status in the sidebar", isOn: $settings.showsPullRequestStatus)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                } label: {
                    Text("Show PR status in the sidebar")
                    Text("Requires `gh` to be installed")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("GitHub")
            }

            LinearSettingsSection()

            RemoteDevicesSettingsSection()
        }
        .formStyle(.grouped)
        .task {
            ghInstalled = await Task.detached {
                ClaudeCLILocator.isAvailable(commandName: "gh", refresh: true)
            }.value
        }
    }
}
