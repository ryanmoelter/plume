import SwiftUI

struct IntegrationsSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var newIgnoredCheckName = ""
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

            Section {
                ForEach(settings.ignoredPendingChecks, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            settings.ignoredPendingChecks.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Ignored pending check name(s)", text: $newIgnoredCheckName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIgnoredCheck)
                    Button("Add", action: addIgnoredCheck)
                        .disabled(newIgnoredCheckName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                GitConfigIgnoredChecksRow()
            } header: {
                Text("Ignored pending checks")
            } footer: {
                Text("These checks don't count towards a pending state, e.g. if they're waiting for approval to run. They only count if they're a pass or fail.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            ghInstalled = await Task.detached {
                ClaudeCLILocator.isAvailable(commandName: "gh", refresh: true)
            }.value
        }
    }

    private func addIgnoredCheck() {
        let names = newIgnoredCheckName
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !settings.ignoredPendingChecks.contains($0) }
        settings.ignoredPendingChecks.append(contentsOf: names)
        newIgnoredCheckName = ""
    }
}
